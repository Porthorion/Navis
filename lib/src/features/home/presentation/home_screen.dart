import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/api/models/listenbrainz_playlist.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/album_card.dart';
import 'package:navis/src/common_widgets/album_context_menu.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/hero_cover_art.dart';
import 'package:navis/src/common_widgets/navis_icon.dart';
import 'package:navis/src/common_widgets/song_context_menu.dart';
import 'package:navis/src/common_widgets/song_download_status_icon.dart';
import 'package:navis/src/common_widgets/track_list_tile.dart';
import 'package:navis/src/common_widgets/empty_state.dart';
import 'package:navis/src/common_widgets/error_state.dart';
import 'package:navis/src/common_widgets/shimmer_placeholder.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/changelog/changelog_data.dart';
import 'package:navis/src/features/changelog/changelog_dialog.dart';
import 'package:navis/src/features/changelog/changelog_provider.dart';
import 'package:navis/src/features/downloads/presentation/download_quality_sheet.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_active_session_indicator.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_settings_provider.dart';
import 'package:navis/src/features/home/domain/home_section_ids.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/library/domain/toggle_song_star.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/settings/presentation/update_dialog.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_theme.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:url_launcher/url_launcher.dart';

export 'package:navis/src/features/home/domain/home_section_ids.dart';

part 'home_support_widgets.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class ListenBrainzWeeklyDetailScreen extends ConsumerWidget {
  const ListenBrainzWeeklyDetailScreen({
    required this.sourcePatch,
    super.key,
  });

  final String sourcePatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlistsAsync = ref.watch(listenBrainzDiscoverStreamProvider);
    final playlist = playlistsAsync.asData?.value
        .where((playlist) => playlist.playlist.sourcePatch == sourcePatch)
        .firstOrNull;
    final title = switch (sourcePatch) {
      'weekly-jams' => 'Weekly Jams',
      'weekly-exploration' => 'Weekly Exploration',
      _ => 'ListenBrainz Weekly',
    };
    final adaptiveContext = resolveAdaptiveContextFor(context);

    return Scaffold(
      appBar: (adaptiveContext.useDesktopShell || playlist == null)
          ? AppBar(title: Text(title))
          : null,
      body: playlistsAsync.when(
        data: (_) {
          if (playlist == null) {
            return const EmptyState(
              icon: Icons.auto_awesome_outlined,
              title: 'No weekly playlist available',
              subtitle: 'Refresh You Might Like to fetch it again.',
            );
          }
          return _ListenBrainzWeeklyDetailContent(playlist: playlist);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          title: 'Could not load weekly playlist',
          message: error.toString(),
          onRetry: () {
            ref
                .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
                .refresh();
          },
        ),
      ),
    );
  }
}

class _ListenBrainzWeeklyDetailContent extends ConsumerStatefulWidget {
  const _ListenBrainzWeeklyDetailContent({required this.playlist});

  final ListenBrainzDiscoverPlaylist playlist;

  @override
  ConsumerState<_ListenBrainzWeeklyDetailContent> createState() =>
      _ListenBrainzWeeklyDetailContentState();
}

class _ListenBrainzWeeklyDetailContentState
    extends ConsumerState<_ListenBrainzWeeklyDetailContent> {
  DownloadQualityChoice? _pendingDownloadChoice;
  final Set<String> _downloadIntentQueuedSongIds = <String>{};

  ListenBrainzDiscoverPlaylist get playlist => widget.playlist;

  @override
  void didUpdateWidget(_ListenBrainzWeeklyDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlist.playlist.identifier !=
        widget.playlist.playlist.identifier) {
      _pendingDownloadChoice = null;
      _downloadIntentQueuedSongIds.clear();
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
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () => context.pop(),
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

    return CustomScrollView(
      slivers: <Widget>[
        SliverAppBar(
          key: const ValueKey<String>('albumDetailMobileExpandedArtAppBar'),
          pinned: true,
          expandedHeight: MediaQuery.sizeOf(context).width,
          title: Text(playlist.displayTitle),
          flexibleSpace: FlexibleSpaceBar(
            background: _ListenBrainzArtwork(
              playlist: playlist,
              size: MediaQuery.sizeOf(context).width,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: _VirtualAlbumHeaderText(
              playlist: playlist,
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

  List<SongsTableData> get _serverSongs => playlist.recommendations
      .where((recommendation) => recommendation.hasServerSong)
      .map((recommendation) => recommendation.tableSong!)
      .toList(growable: false);

  Widget _buildActions(
    List<SongsTableData> serverSongs, {
    bool iconOnly = false,
  }) {
    final l10n = AppLocalizations.of(context)!;
    if (iconOnly) {
      return Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          IconButton(
            tooltip: l10n.albumDetailPlayAction,
            icon: const Icon(Icons.play_arrow),
            onPressed: serverSongs.isEmpty
                ? null
                : () => _queueSongs(serverSongs, shuffle: false),
          ),
          IconButton(
            tooltip: l10n.albumDetailShuffleAction,
            icon: const Icon(Icons.shuffle),
            onPressed: serverSongs.isEmpty
                ? null
                : () => _queueSongs(serverSongs, shuffle: true),
          ),
          IconButton(
            tooltip: l10n.albumDetailDownloadAction,
            icon: const Icon(Icons.download_outlined),
            onPressed: serverSongs.isEmpty ? null : _downloadVirtualAlbum,
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
          onPressed: serverSongs.isEmpty
              ? null
              : () => _queueSongs(serverSongs, shuffle: false),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(l10n.albumDetailPlayAction),
        ),
        FilledButton.tonalIcon(
          onPressed: serverSongs.isEmpty
              ? null
              : () => _queueSongs(serverSongs, shuffle: true),
          icon: const Icon(Icons.shuffle_rounded),
          label: Text(l10n.albumDetailShuffleAction),
        ),
        OutlinedButton.icon(
          onPressed: serverSongs.isEmpty ? null : _downloadVirtualAlbum,
          icon: const Icon(Icons.download_outlined),
          label: Text(l10n.albumDetailDownloadAction),
        ),
      ],
    );
  }

  SliverList _buildTrackSliver({required bool compact}) {
    return SliverList.builder(
      itemCount: playlist.recommendations.length,
      itemBuilder: (context, index) {
        final recommendation = playlist.recommendations[index];
        final tableSong = recommendation.tableSong;
        if (recommendation.hasServerSong && tableSong != null) {
          return TrackListTile(
            song: tableSong.copyWith(track: Value(index + 1)),
            contentPadding: compact
                ? const EdgeInsetsDirectional.only(start: 8, end: 4)
                : null,
            horizontalTitleGap: 6,
            onTap: () => _playFrom(index),
            onLongPress: () => showSongContextMenu(context, ref, tableSong),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SongDownloadStatusIcon(
                  songId: tableSong.id,
                  onDownload: () => _downloadSong(tableSong),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () => showSongContextMenu(context, ref, tableSong),
                ),
              ],
            ),
          );
        }
        return _ListenBrainzRecommendationTile(
          recommendation: recommendation,
          index: index + 1,
          onPlay: (song) {
            ref.read(queueProvider.notifier).replaceWithSongs(<Song>[
              song,
            ]).ignore();
          },
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

  void _queueSongs(List<SongsTableData> songs, {required bool shuffle}) {
    final queueSongs = List<SongsTableData>.of(songs);
    if (shuffle) {
      queueSongs.shuffle(math.Random());
    }
    ref.read(queueProvider.notifier).replaceWithTableData(queueSongs).ignore();
  }

  void _playFrom(int recommendationIndex) {
    final serverSongs = <SongsTableData>[];
    var startIndex = 0;
    for (var i = 0; i < playlist.recommendations.length; i++) {
      final recommendation = playlist.recommendations[i];
      if (!recommendation.hasServerSong) continue;
      if (i == recommendationIndex) {
        startIndex = serverSongs.length;
      }
      serverSongs.add(recommendation.tableSong!);
    }
    ref
        .read(queueProvider.notifier)
        .replaceWithTableData(serverSongs, startIndex: startIndex)
        .ignore();
  }

  Future<void> _downloadVirtualAlbum() async {
    final choice = await showDownloadQualitySheet(context);
    if (choice == null || !mounted) return;
    setState(() {
      _pendingDownloadChoice = choice;
      _downloadIntentQueuedSongIds.clear();
    });
    final count = await _enqueueDownloads(_serverSongs, choice);
    if (!mounted) return;
    showAppNotice(
      context,
      message: AppLocalizations.of(context)!.downloadAlbumQueued(count),
      level: AppNoticeLevel.success,
    );
  }

  Future<void> _downloadSong(SongsTableData song) async {
    final choice = await showDownloadQualitySheet(context);
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
      message: AppLocalizations.of(context)!.downloadSongQueued,
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
  const _VirtualAlbumHeaderText({
    required this.playlist,
    required this.titleStyle,
    required this.metadataStyle,
    this.actions,
    this.textAlign = TextAlign.center,
    this.compact = false,
  });

  final ListenBrainzDiscoverPlaylist playlist;
  final TextStyle? titleStyle;
  final TextStyle? metadataStyle;
  final Widget? actions;
  final TextAlign textAlign;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final date = _listenBrainzGenerationDate(playlist);
    final metadata = <String>[
      'ListenBrainz',
      _formatListenBrainzDate(date),
      '${playlist.totalCount} tracks',
      playlist.matchingComplete
          ? '${playlist.matchedCount} available'
          : '${playlist.matchedCount} available, matching',
    ].join(' • ');
    return Column(
      crossAxisAlignment: textAlign == TextAlign.center
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          playlist.displayTitle,
          textAlign: textAlign,
          maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        const SizedBox(height: 8),
        Text(
          metadata,
          textAlign: textAlign,
          maxLines: compact ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: metadataStyle,
        ),
        if (actions != null) ...<Widget>[
          const SizedBox(height: 20),
          actions!,
        ],
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

String _formatListenBrainzDate(DateTime date) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
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
    await ref
        .read(librarySyncControllerProvider.notifier)
        .syncNow(preferIncremental: true);
    ref.invalidate(homeRecentlyAddedProvider);
    ref.invalidate(homeRandomAlbumsProvider);
    ref.invalidate(homeDownloadedRandomAlbumsProvider);
    ref.invalidate(homeRandomAlbumShowcaseProvider);
    ref.invalidate(homeRandomShowcaseProvider);
    ref.read(listenBrainzDiscoverRefreshEpochProvider.notifier).refresh();
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
    _homePullSpringAnimation =
        Tween<double>(
          begin: _homePullProgress,
          end: 0,
        ).animate(
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
    final syncState = ref.watch(librarySyncControllerProvider);
    ref.listen(homeScrollToTopRequestProvider, (previous, next) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    // Show the "What's New" dialog once per version, after the first frame.
    ref.listen<AsyncValue<ChangelogVersion?>>(
      changelogToShowProvider,
      (_, next) {
        final version = next.asData?.value;
        if (version == null || !mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showChangelogDialog(context, version);
        });
      },
    );

    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final likedOnly = ref.watch(homeLikedOnlyFilterProvider);
    final adaptiveContext = resolveAdaptiveContextFor(context);
    final adaptiveLayoutClass = adaptiveContext.adaptiveLayoutClass;
    final compactWideLandscapeMode = adaptiveContext.useCompactWideLandscape;
    final compactHorizontalInset = compactWideLandscapeMode ? 10.0 : 0.0;
    final tabletMode =
        !adaptiveContext.useDesktopShell &&
        adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;
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
                  syncState: syncState,
                  pullProgress: 0,
                  showImmediateRefreshRing: false,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
                  syncState: syncState,
                  pullProgress: useCustomHomePullRefresh
                      ? _homePullProgress
                      : 0,
                  showImmediateRefreshRing:
                      useCustomHomePullRefresh &&
                      _homeImmediateTriggerRingVisible &&
                      !syncState.isRunning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.appName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
                syncState: syncState,
                pullProgress: useCustomHomePullRefresh ? _homePullProgress : 0,
                showImmediateRefreshRing:
                    useCustomHomePullRefresh &&
                    _homeImmediateTriggerRingVisible &&
                    !syncState.isRunning,
              ),
            ),
          ),
          const _HomeActionRow(variant: _HomeActionRowVariant.mobile),
          const SizedBox(height: 10),
        ],
        const _UpdateBanner(),
        for (final sectionId in order)
          if (!hidden.contains(sectionId))
            ..._buildSection(
              context,
              ref,
              sectionId,
              downloadedOnly,
              likedOnly,
              syncState.isRunning,
              homeDensity,
              desktopRuntime,
              desktopMode,
              adaptiveLayoutClass,
              compactWideLandscapeMode,
            ),
      ],
    );

    final contentMaxWidth = switch (adaptiveLayoutClass) {
      AdaptiveLayoutClass.phoneCompact => double.infinity,
      AdaptiveLayoutClass.tabletMedium => 880.0,
      AdaptiveLayoutClass.tabletExpanded =>
        compactWideLandscapeMode ? double.infinity : 1040.0,
    };

    final resolvedContent = tabletMode && !compactWideLandscapeMode
        ? Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: contentMaxWidth),
              child: content,
            ),
          )
        : content;

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
              onTap: (album) =>
                  NavService.openAlbumDetail(context, ref, album.id),
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
                onTap: (album) =>
                    NavService.openAlbumDetail(context, ref, album.id),
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
              onTap: (album) =>
                  NavService.openAlbumDetail(context, ref, album.id),
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
              onTap: (album) =>
                  NavService.openAlbumDetail(context, ref, album.id),
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
            builder: (context, albums) => desktopMode
                ? _DesktopRandomAlbumsPager(
                    albums: albums,
                    heroContext: 'home_random',
                    density: sectionDensity,
                  )
                : _RandomAlbumsHeroCarousel(
                    albums: albums,
                    heroContext: 'home_random',
                    density: sectionDensity,
                    freezeListUpdates: syncRunning,
                    desktopMode: desktopMode,
                    adaptiveLayoutClass: adaptiveLayoutClass,
                  ),
            emptyTitle: l10n.homeRandomEmptyTitle,
            emptySubtitle: l10n.homeRandomEmptySubtitle,
            onRetry: () {
              ref.invalidate(homeRandomAlbumsProvider);
              ref.invalidate(homeRandomAlbumShowcaseProvider);
              ref
                  .read(listenBrainzDiscoverRefreshEpochProvider.notifier)
                  .refresh();
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
                          .where(
                            (song) => !likedOnly || song.starred != null,
                          )
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
              onTap: (album) =>
                  NavService.openAlbumDetail(context, ref, album.id),
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

class _HomeSyncLogo extends StatelessWidget {
  const _HomeSyncLogo({
    required this.size,
    required this.syncState,
    this.pullProgress = 0,
    this.showImmediateRefreshRing = false,
  });

  static const Key ringKey = ValueKey<String>('home-sync-ring');
  // The source PNG's visible glyph is slightly right/down from canvas center.
  // Apply a tiny counter-shift so the ring and icon appear optically centered.
  static const double _assetCenterOffsetX = 12.5 / 1024.0;
  static const double _assetCenterOffsetY = 3.5 / 1024.0;

  final double size;
  final LibrarySyncState syncState;
  final double pullProgress;
  final bool showImmediateRefreshRing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final accentColors = NavisAccentColors.of(context);
    final clampedPullProgress = pullProgress.clamp(0.0, 1.0);
    final isRunning = syncState.isRunning;
    final hasDeterminate = isRunning && (syncState.total ?? 0) > 0;
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
    final iconOffset = Offset(
      -(size * _assetCenterOffsetX),
      -(size * _assetCenterOffsetY),
    );

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
            Transform.translate(
              offset: iconOffset,
              child: NavisIcon(
                size: size,
                tintWithAccent: true,
              ),
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
    this.desktopMode = false,
    this.adaptiveLayoutClass = AdaptiveLayoutClass.phoneCompact,
    this.compactWideLandscapeMode = false,
    this.template = _HomeSectionTemplate.carousel,
    this.density = _HomeSectionDensity.comfortable,
    this.loadingBuilder,
    this.keepPreviousDataWhileLoading = false,
    this.onRetry,
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final compactDensity = density == _HomeSectionDensity.compact;
    final titleWidget = Text(
      title,
      style:
          (template == _HomeSectionTemplate.compactList
                  ? Theme.of(context).textTheme.titleMedium
                  : Theme.of(context).textTheme.titleLarge)
              ?.copyWith(fontWeight: FontWeight.w700),
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
        child: ErrorState(
          title: l10n.homeLoadErrorTitle,
          message: error.toString(),
          onRetry: onRetry,
        ),
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
          ? DesktopPanel(
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
  const _ServerAlbumCarousel({
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
  final void Function(Album album) onTap;
  final String heroContext;
  final bool desktopMode;
  final bool tabletMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = coverArtShapeToRadius(coverShape);
    final compactDensity = density == _HomeSectionDensity.compact;
    final cardSize = desktopMode
        ? (compactDensity ? 152.0 : 164.0)
        : tabletMode
        ? (adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded
              ? (compactDensity ? 164.0 : 176.0)
              : (compactDensity ? 152.0 : 162.0))
        : (compactDensity ? 138.0 : 150.0);
    final horizontalPadding = desktopMode
        ? 0.0
        : (tabletMode ? (compactWideLandscapeMode ? 0.0 : 12.0) : 16.0);
    final separatorWidth = compactDensity ? 10.0 : (tabletMode ? 14.0 : 12.0);
    if (desktopMode) {
      return _DesktopScrollableCarousel(
        height: cardSize,
        horizontalPadding: horizontalPadding,
        separatorWidth: separatorWidth,
        itemCount: albums.length,
        itemBuilder: (context, index) {
          final album = albums[index];
          return _ServerAlbumCard(
            name: album.name,
            artist: album.artist,
            coverArtId: album.coverArt,
            width: cardSize,
            borderRadius: coverRadius,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: '${heroContext}_${album.id}',
            ),
            onTap: () => onTap(album),
            onLongPress: () => showAlbumContextMenu(context, ref, album.id),
            onSecondaryTapDown: (details) => showAlbumContextMenu(
              context,
              ref,
              album.id,
              anchor: details.globalPosition,
            ),
          );
        },
      );
    }
    return SizedBox(
      height: cardSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        itemCount: albums.length,
        separatorBuilder: (_, _) => SizedBox(width: separatorWidth),
        itemBuilder: (context, index) {
          final album = albums[index];
          return _ServerAlbumCard(
            name: album.name,
            artist: album.artist,
            coverArtId: album.coverArt,
            width: cardSize,
            borderRadius: coverRadius,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: '${heroContext}_${album.id}',
            ),
            onTap: () => onTap(album),
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
  }
}

/// Carousel for [AlbumsTableData] objects from the local database.
class _LocalAlbumCarousel extends ConsumerWidget {
  const _LocalAlbumCarousel({
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
  final void Function(AlbumsTableData album) onTap;
  final String heroContext;
  final bool desktopMode;
  final bool tabletMode;
  final AdaptiveLayoutClass adaptiveLayoutClass;
  final bool compactWideLandscapeMode;
  final _HomeSectionDensity density;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compactDensity = density == _HomeSectionDensity.compact;
    final cardSize = desktopMode
        ? (compactDensity ? 152.0 : 164.0)
        : tabletMode
        ? (adaptiveLayoutClass == AdaptiveLayoutClass.tabletExpanded
              ? (compactDensity ? 164.0 : 176.0)
              : (compactDensity ? 152.0 : 162.0))
        : (compactDensity ? 138.0 : 150.0);
    final horizontalPadding = desktopMode
        ? 0.0
        : (tabletMode ? (compactWideLandscapeMode ? 0.0 : 12.0) : 16.0);
    final separatorWidth = compactDensity ? 10.0 : (tabletMode ? 14.0 : 12.0);
    if (desktopMode) {
      return _DesktopScrollableCarousel(
        height: cardSize,
        horizontalPadding: horizontalPadding,
        separatorWidth: separatorWidth,
        itemCount: albums.length,
        itemBuilder: (context, index) {
          final album = albums[index];
          return AlbumCard(
            album: album,
            size: AlbumCardSize.compact,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: '${heroContext}_${album.id}',
            ),
            onTap: () => onTap(album),
            onLongPress: () => showAlbumContextMenu(context, ref, album.id),
            onSecondaryTapDown: (details) => showAlbumContextMenu(
              context,
              ref,
              album.id,
              anchor: details.globalPosition,
            ),
          );
        },
      );
    }
    return SizedBox(
      height: cardSize,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        itemCount: albums.length,
        separatorBuilder: (_, _) => SizedBox(width: separatorWidth),
        itemBuilder: (context, index) {
          final album = albums[index];
          return AlbumCard(
            album: album,
            size: AlbumCardSize.compact,
            heroTag: buildCoverArtHeroTag(
              coverArtId: album.coverArt,
              context: '${heroContext}_${album.id}',
            ),
            onTap: () => onTap(album),
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
  }
}

class _DesktopScrollableCarousel extends StatefulWidget {
  const _DesktopScrollableCarousel({
    required this.height,
    required this.horizontalPadding,
    required this.separatorWidth,
    required this.itemCount,
    required this.itemBuilder,
  });

  final double height;
  final double horizontalPadding;
  final double separatorWidth;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<_DesktopScrollableCarousel> createState() =>
      _DesktopScrollableCarouselState();
}

class _DesktopScrollableCarouselState
    extends State<_DesktopScrollableCarousel> {
  static const double _edgeButtonSize = 34;

  late final ScrollController _scrollController;
  bool _canScrollBackward = false;
  bool _canScrollForward = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()..addListener(_syncArrowState);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrowState());
  }

  @override
  void didUpdateWidget(covariant _DesktopScrollableCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncArrowState());
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_syncArrowState)
      ..dispose();
    super.dispose();
  }

  void _syncArrowState() {
    if (!_scrollController.hasClients) {
      if (_canScrollBackward || _canScrollForward) {
        setState(() {
          _canScrollBackward = false;
          _canScrollForward = false;
        });
      }
      return;
    }
    final position = _scrollController.position;
    final nextBackward = position.pixels > 1;
    final nextForward = (position.maxScrollExtent - position.pixels) > 1;
    if (nextBackward == _canScrollBackward &&
        nextForward == _canScrollForward) {
      return;
    }
    setState(() {
      _canScrollBackward = nextBackward;
      _canScrollForward = nextForward;
    });
  }

  void _animateBy(double delta) {
    if (!_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canHaveArrows = widget.itemCount > 1;
    return SizedBox(
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportJump = constraints.maxWidth * 0.72;
          final list = ListView.separated(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            itemCount: widget.itemCount,
            separatorBuilder: (_, _) => SizedBox(width: widget.separatorWidth),
            itemBuilder: widget.itemBuilder,
          );
          if (!canHaveArrows) {
            return list;
          }
          return Stack(
            children: <Widget>[
              Positioned.fill(child: list),
              if (_canScrollBackward)
                Align(
                  alignment: Alignment.centerLeft,
                  child: _CarouselEdgeArrow(
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => _animateBy(-viewportJump),
                  ),
                ),
              if (_canScrollForward)
                Align(
                  alignment: Alignment.centerRight,
                  child: _CarouselEdgeArrow(
                    icon: Icons.chevron_right_rounded,
                    onPressed: () => _animateBy(viewportJump),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CarouselEdgeArrow extends StatelessWidget {
  const _CarouselEdgeArrow({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: colors.surfaceContainerHigh.withValues(alpha: 0.92),
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: _DesktopScrollableCarouselState._edgeButtonSize,
            height: _DesktopScrollableCarouselState._edgeButtonSize,
            child: Icon(icon),
          ),
        ),
      ),
    );
  }
}

class _DesktopRandomAlbumsPager extends ConsumerStatefulWidget {
  const _DesktopRandomAlbumsPager({
    required this.albums,
    required this.heroContext,
    this.density = _HomeSectionDensity.comfortable,
  });

  final List<HomeRandomShowcaseItem> albums;
  final String heroContext;
  final _HomeSectionDensity density;

  @override
  ConsumerState<_DesktopRandomAlbumsPager> createState() =>
      _DesktopRandomAlbumsPagerState();
}

class _DesktopRandomAlbumsPagerState
    extends ConsumerState<_DesktopRandomAlbumsPager> {
  late final PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didUpdateWidget(covariant _DesktopRandomAlbumsPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.albums.isEmpty) {
      if (_currentPage != 0) {
        setState(() {
          _currentPage = 0;
        });
      }
      return;
    }
    final clampedPage = _currentPage.clamp(0, widget.albums.length - 1);
    if (_currentPage != clampedPage) {
      setState(() {
        _currentPage = clampedPage;
      });
      if (_pageController.hasClients) {
        _pageController.jumpToPage(clampedPage);
      }
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _animateToPage(int target) {
    if (!_pageController.hasClients || widget.albums.isEmpty) {
      return;
    }
    final clampedTarget = target.clamp(0, widget.albums.length - 1);
    if (clampedTarget == _currentPage) {
      return;
    }
    _pageController.animateToPage(
      clampedTarget,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  double _heroHeightFor(double availableWidth) {
    final compact = widget.density == _HomeSectionDensity.compact;
    return (availableWidth * (compact ? 0.26 : 0.29)).clamp(
      compact ? 300.0 : 330.0,
      compact ? 430.0 : 470.0,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.albums.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      key: const ValueKey<String>('home-random-desktop-pager'),
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final height = _heroHeightFor(availableWidth);
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
                      itemCount: widget.albums.length,
                      onPageChanged: (page) {
                        if (!mounted) {
                          return;
                        }
                        setState(() {
                          _currentPage = page;
                        });
                      },
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: KeyedSubtree(
                            key: ValueKey<String>(
                              'home-random-desktop-page-$index',
                            ),
                            child: _DesktopRandomAlbumPage(
                              album: widget.albums[index],
                              heroContext: widget.heroContext,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (widget.albums.length > 1 && _currentPage > 0)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _CarouselEdgeArrow(
                        icon: Icons.chevron_left_rounded,
                        onPressed: () => _animateToPage(_currentPage - 1),
                      ),
                    ),
                  if (widget.albums.length > 1 &&
                      _currentPage < widget.albums.length - 1)
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
        if (widget.albums.length > 1) ...<Widget>[
          const SizedBox(height: 10),
          _DesktopRandomMiniCoverStrip(
            albums: widget.albums,
            currentPage: _currentPage,
            onPageSelected: _animateToPage,
          ),
        ],
      ],
    );
  }
}

class _DesktopRandomAlbumPage extends ConsumerWidget {
  const _DesktopRandomAlbumPage({
    required this.album,
    required this.heroContext,
  });

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
                    borderRadius: BorderRadius.circular(20),
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
  const _DesktopRandomAlbumVisual({
    required this.album,
    required this.heroContext,
  });

  final HomeRandomShowcaseAlbum album;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = coverArtShapeToRadius(coverShape);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => NavService.openAlbumDetail(context, ref, album.id),
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
                    heroTag: buildCoverArtHeroTag(
                      coverArtId: album.coverArtId,
                      context: '${heroContext}_${album.id}_desktop_page',
                      entityId: album.id,
                    ),
                    size: kCoverArtStandardSize,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                  ),
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
                              style: Theme.of(context).textTheme.bodyMedium
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
          ),
        ),
      ),
    );
  }
}

class _DesktopListenBrainzPage extends ConsumerWidget {
  const _DesktopListenBrainzPage({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pageHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 330.0;
        final coverWidth = math.min(pageHeight, constraints.maxWidth * 0.44);
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
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.outlineVariant.withValues(alpha: 0.34),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: _DesktopListenBrainzSongList(item: item),
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
  const _ListenBrainzShowcaseVisual({
    required this.item,
  });

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        onTap: item.isLoading
            ? null
            : () => _showListenBrainzDiscoverDetail(
                context,
                ref,
                item.playlist!,
              ),
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
                    item.displayTitle,
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
                        ? 'Fetching ListenBrainz playlist...'
                        : _listenBrainzAvailabilityText(item.playlist!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.78),
                    ),
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

class _DesktopListenBrainzSongList extends ConsumerWidget {
  const _DesktopListenBrainzSongList({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    if (item.isLoading || item.playlist == null) {
      return Center(
        child: Text(
          'Fetching playlist...',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    final recommendations = item.playlist!.recommendations;
    if (recommendations.isEmpty) {
      return Center(
        child: Text(
          'No tracks yet',
          style: theme.textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: recommendations.length,
      itemBuilder: (context, index) {
        return _ListenBrainzRecommendationTile(
          recommendation: recommendations[index],
          index: index + 1,
          onPlay: (song) {
            ref.read(queueProvider.notifier).replaceWithSongs(<Song>[
              song,
            ]).ignore();
          },
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

class _ListenBrainzLoadingArtwork extends StatelessWidget {
  const _ListenBrainzLoadingArtwork();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
      ),
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
  const _DesktopRandomAlbumSongList({required this.album});

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

    const preferredRowHeight = 52.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        return ListView.separated(
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
              rowHeight: preferredRowHeight,
            );
          },
        );
      },
    );
  }
}

class _DesktopRandomAlbumSongRow extends ConsumerWidget {
  const _DesktopRandomAlbumSongRow({
    required this.song,
    required this.albumTracks,
    required this.queueStartIndex,
    required this.displayIndex,
    required this.rowHeight,
  });

  final SongsTableData song;
  final List<SongsTableData> albumTracks;
  final int queueStartIndex;
  final int displayIndex;
  final double rowHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final currentSongId = ref.watch(currentSongProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final isCurrentSong = currentSongId == song.id;
    final isLiked =
        ref.watch(songStarredProvider(song.id)).asData?.value ??
        song.starred != null;

    Future<void> openMenuWithAnchor(Offset anchor) {
      return showSongContextMenu(
        context,
        ref,
        song,
        anchor: anchor,
      );
    }

    return SizedBox(
      key: ValueKey<String>('home-random-desktop-song-row-${song.id}'),
      height: rowHeight,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          mouseCursor: SystemMouseCursors.click,
          hoverColor: colors.primary.withValues(alpha: 0.06),
          highlightColor: colors.primary.withValues(alpha: 0.08),
          onTap: () {
            unawaited(
              ref
                  .read(queueProvider.notifier)
                  .replaceWithTableData(
                    albumTracks,
                    startIndex: queueStartIndex,
                    autoPlay: true,
                  ),
            );
          },
          onSecondaryTapDown: (details) {
            unawaited(openMenuWithAnchor(details.globalPosition));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 24,
                  child: isCurrentSong && isPlaying
                      ? Icon(
                          Icons.graphic_eq_rounded,
                          size: 17,
                          color: colors.primary,
                        )
                      : Text(
                          '$displayIndex',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colors.onSurfaceVariant.withValues(
                                  alpha: 0.75,
                                ),
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 30,
                  child: IconButton(
                    key: ValueKey<String>(
                      'home-random-desktop-heart-${song.id}',
                    ),
                    visualDensity: const VisualDensity(
                      horizontal: -4,
                      vertical: -4,
                    ),
                    padding: EdgeInsets.zero,
                    iconSize: 18,
                    icon: Icon(
                      isLiked ? Icons.favorite : Icons.favorite_border,
                      color: isLiked
                          ? colors.primary
                          : colors.onSurfaceVariant.withValues(alpha: 0.88),
                    ),
                    onPressed: () {
                      unawaited(
                        toggleSongStar(song.id, ref).catchError((_) {
                          if (context.mounted) {
                            showAppNotice(
                              context,
                              message: l10n.albumDetailStarFailure,
                              level: AppNoticeLevel.error,
                            );
                          }
                        }),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                      ),
                      if (song.artistName != null &&
                          song.artistName!.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 1),
                        Text(
                          song.artistName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: colors.onSurfaceVariant.withValues(
                                  alpha: 0.8,
                                ),
                              ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 32,
                  child: Builder(
                    builder: (buttonContext) => IconButton(
                      key: ValueKey<String>(
                        'home-random-desktop-menu-${song.id}',
                      ),
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      color: colors.primary.withValues(alpha: 0.9),
                      icon: const Icon(Icons.more_horiz_rounded),
                      onPressed: () {
                        final renderBox =
                            buttonContext.findRenderObject() as RenderBox?;
                        Offset? anchor;
                        if (renderBox != null) {
                          anchor = renderBox.localToGlobal(
                            Offset(
                              renderBox.size.width / 2,
                              renderBox.size.height / 2,
                            ),
                          );
                        }
                        if (anchor != null) {
                          unawaited(openMenuWithAnchor(anchor));
                        } else {
                          unawaited(showSongContextMenu(context, ref, song));
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 48,
                  child: Text(
                    formatSeconds(song.duration),
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant.withValues(alpha: 0.86),
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
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

class _DesktopRandomMiniCoverStrip extends ConsumerWidget {
  const _DesktopRandomMiniCoverStrip({
    required this.albums,
    required this.currentPage,
    required this.onPageSelected,
  });

  final List<HomeRandomShowcaseItem> albums;
  final int currentPage;
  final ValueChanged<int> onPageSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coverShape = ref.watch(coverArtShapeProvider);
    final coverRadius = coverArtShapeToRadius(coverShape);
    final colors = Theme.of(context).colorScheme;

    return SizedBox(
      height: 42,
      child: Align(
        alignment: Alignment.center,
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
      ),
    );
  }
}

class _RandomMiniCover extends StatelessWidget {
  const _RandomMiniCover({
    required this.item,
    required this.borderRadius,
  });

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
  const _RandomAlbumsHeroCarousel({
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
    extends ConsumerState<_RandomAlbumsHeroCarousel> {
  static const int _kVirtualLoopCycles = 10000;
  late final PageController _pageController;
  late List<HomeRandomShowcaseItem> _displayedAlbums;
  Timer? _autoAdvanceTimer;
  Timer? _resumeTimer;
  bool _autoAdvancePaused = false;
  int _currentVirtualPage = 0;
  int _currentLogicalPage = 0;

  @override
  void initState() {
    super.initState();
    _displayedAlbums = List<HomeRandomShowcaseItem>.unmodifiable(
      widget.albums,
    );
    final initialPage = _initialVirtualPage(_displayedAlbums.length);
    _currentVirtualPage = initialPage;
    _currentLogicalPage = _logicalIndexForPage(
      initialPage,
      _displayedAlbums.length,
    );
    _pageController = PageController(
      viewportFraction: widget.desktopMode ? 0.58 : 0.84,
      initialPage: initialPage,
    );
    _startAutoAdvance();
  }

  @override
  void didUpdateWidget(covariant _RandomAlbumsHeroCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incomingAlbums = List<HomeRandomShowcaseItem>.unmodifiable(
      widget.albums,
    );

    if (oldWidget.desktopMode != widget.desktopMode) {
      final currentPage = _currentVirtualPage;
      final previousController = _pageController;
      _pageController = PageController(
        viewportFraction: widget.desktopMode ? 0.58 : 0.84,
        initialPage: currentPage,
      );
      previousController.dispose();
    }

    if (widget.freezeListUpdates && _displayedAlbums.isNotEmpty) {
      return;
    }

    final oldIds = _displayedAlbums.map((album) => album.stableId).toList();
    final newIds = incomingAlbums.map((album) => album.stableId).toList();
    final contentChanged = !listEquals(oldIds, newIds);
    if (!contentChanged) {
      _displayedAlbums = incomingAlbums;
      return;
    }

    final previousDisplayedAlbums = _displayedAlbums;
    _displayedAlbums = incomingAlbums;

    if (_displayedAlbums.isEmpty) {
      _currentVirtualPage = 0;
      _currentLogicalPage = 0;
      _stopAutoAdvance();
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
    var nextLogicalPage = 0;
    if (currentAlbumId != null) {
      final matchedIndex = newIds.indexOf(currentAlbumId);
      if (matchedIndex != -1) {
        nextLogicalPage = matchedIndex;
      }
    }
    nextLogicalPage = nextLogicalPage.clamp(0, _displayedAlbums.length - 1);
    _currentLogicalPage = nextLogicalPage;
    _currentVirtualPage = _rebaseVirtualPage(nextLogicalPage);
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_currentVirtualPage);
    }
    _startAutoAdvance();
  }

  @override
  void dispose() {
    _autoAdvanceTimer?.cancel();
    _resumeTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _stopAutoAdvance() {
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = null;
  }

  void _startAutoAdvance() {
    _stopAutoAdvance();
    if (_displayedAlbums.length <= 1) {
      return;
    }
    _autoAdvanceTimer = Timer.periodic(const Duration(milliseconds: 4200), (_) {
      if (!mounted || _autoAdvancePaused || !_pageController.hasClients) {
        return;
      }
      final nextIndex = _currentVirtualPage + 1;
      _pageController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 460),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _pauseAutoAdvanceTemporarily() {
    if (!mounted) {
      return;
    }
    _autoAdvancePaused = true;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(const Duration(milliseconds: 2200), () {
      _autoAdvancePaused = false;
    });
  }

  void _animateToRelativePage(int delta) {
    if (!mounted ||
        !_pageController.hasClients ||
        _displayedAlbums.length <= 1) {
      return;
    }
    _pauseAutoAdvanceTemporarily();
    _pageController.animateToPage(
      _currentVirtualPage + delta,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

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

  double _heroHeightFor(double availableWidth) {
    final compact = widget.density == _HomeSectionDensity.compact;
    if (widget.desktopMode) {
      return (availableWidth * (compact ? 0.28 : 0.32)).clamp(
        compact ? 260.0 : 300.0,
        compact ? 420.0 : 500.0,
      );
    }
    return switch (widget.adaptiveLayoutClass) {
      AdaptiveLayoutClass.phoneCompact => compact ? 208 : 228,
      AdaptiveLayoutClass.tabletMedium => compact ? 224 : 244,
      AdaptiveLayoutClass.tabletExpanded => compact ? 236 : 258,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_displayedAlbums.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentPageLabel =
        'home-random-hero-carousel-page-${_currentLogicalPage.clamp(0, _displayedAlbums.length - 1)}';

    return Column(
      children: <Widget>[
        LayoutBuilder(
          builder: (context, constraints) {
            final availableWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final height = _heroHeightFor(availableWidth);

            Widget carouselViewport = PageView.builder(
              key: const ValueKey<String>('home-random-hero-carousel'),
              controller: _pageController,
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
                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.desktopMode ? 8 : 6,
                  ),
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    scale: _currentVirtualPage == index ? 1 : 0.93,
                    child: _RandomAlbumsHeroCard(
                      album: _displayedAlbums[logicalIndex],
                      heroContext: widget.heroContext,
                    ),
                  ),
                );
              },
            );

            if (widget.desktopMode) {
              carouselViewport = ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: <double>[0, 0.08, 0.92, 1],
                ).createShader(bounds),
                blendMode: BlendMode.dstIn,
                child: carouselViewport,
              );
            }

            Widget viewportChild = NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification) {
                  _pauseAutoAdvanceTemporarily();
                } else if (notification is ScrollEndNotification) {
                  _pauseAutoAdvanceTemporarily();
                } else if (notification is UserScrollNotification &&
                    notification.direction == ScrollDirection.idle) {
                  _pauseAutoAdvanceTemporarily();
                }
                return false;
              },
              child: carouselViewport,
            );

            if (widget.desktopMode && _displayedAlbums.length > 1) {
              viewportChild = Stack(
                children: <Widget>[
                  Positioned.fill(child: viewportChild),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _CarouselEdgeArrow(
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => _animateToRelativePage(-1),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: _CarouselEdgeArrow(
                      icon: Icons.chevron_right_rounded,
                      onPressed: () => _animateToRelativePage(1),
                    ),
                  ),
                ],
              );
            }

            return SizedBox(height: height, child: viewportChild);
          },
        ),
        if (_displayedAlbums.length > 1) ...[
          const SizedBox(height: 10),
          Wrap(
            key: ValueKey<String>(currentPageLabel),
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: List<Widget>.generate(
              _displayedAlbums.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: _currentLogicalPage == index ? 16 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: _currentLogicalPage == index
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _RandomAlbumsHeroCard extends ConsumerWidget {
  const _RandomAlbumsHeroCard({
    required this.album,
    required this.heroContext,
  });

  final HomeRandomShowcaseItem album;
  final String heroContext;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = this.album;
    if (item is HomeRandomShowcaseListenBrainz) {
      return _RandomListenBrainzHeroCard(item: item);
    }
    final album = item as HomeRandomShowcaseAlbum;
    final metadataParts = <String>[
      if (album.year != null && album.year! > 0) album.year.toString(),
      if (album.songCount != null && album.songCount! > 0)
        '${album.songCount} tracks',
    ];
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: InkWell(
        onTap: () => NavService.openAlbumDetail(context, ref, album.id),
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
              heroTag: buildCoverArtHeroTag(
                coverArtId: album.coverArtId,
                context: '${heroContext}_hero',
                entityId: album.id,
              ),
              size: kCoverArtStandardSize,
              fit: BoxFit.cover,
              placeholderIcon: Icons.album_outlined,
            ),
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (album.artist != null && album.artist!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          album.artist!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Colors.white.withValues(alpha: 0.86),
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
                                color: Colors.white.withValues(alpha: 0.72),
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
    );
  }
}

class _RandomListenBrainzHeroCard extends ConsumerWidget {
  const _RandomListenBrainzHeroCard({required this.item});

  final HomeRandomShowcaseListenBrainz item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      child: InkWell(
        onTap: item.isLoading
            ? null
            : () => _showListenBrainzDiscoverDetail(
                context,
                ref,
                item.playlist!,
              ),
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
                      item.displayTitle,
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
                          ? 'Fetching ListenBrainz playlist...'
                          : _listenBrainzAvailabilityText(item.playlist!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.86),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.isLoading
                          ? 'Loading'
                          : item.playlist!.matchingComplete
                          ? 'Ready'
                          : 'Matching',
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

String _listenBrainzAvailabilityText(ListenBrainzDiscoverPlaylist playlist) {
  if (!playlist.matchingComplete) {
    return '${playlist.matchedCount} available • matching';
  }
  return '${playlist.matchedCount} of ${playlist.totalCount} available';
}

/// A small square card for server [Album] objects (same visual as [AlbumCard]
/// but accepts the API model directly).
class _ServerAlbumCard extends StatelessWidget {
  const _ServerAlbumCard({
    required this.name,
    required this.borderRadius,
    this.width = 150,
    this.artist,
    this.coverArtId,
    this.heroTag,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTapDown,
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

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
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
            onSecondaryTapDown: onSecondaryTapDown,
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
                    size: kCoverArtStandardSize,
                    fit: BoxFit.cover,
                    placeholderIcon: Icons.album_outlined,
                  )
                else
                  CoverArtImage(
                    coverArtId: coverArtId,
                    size: kCoverArtStandardSize,
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
    if (desktopMode) {
      return Column(
        children: <Widget>[
          for (final song in songs)
            DesktopListRow(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CoverArtImage(
                  coverArtId: song.coverArt,
                  size: 128,
                  width: compactDensity ? 38 : 42,
                  height: compactDensity ? 38 : 42,
                  placeholderIcon: Icons.music_note_outlined,
                ),
              ),
              title: song.title,
              subtitle: song.artistName,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onTap(song),
              onSecondaryTapDown: (details) => showSongContextMenu(
                context,
                ref,
                song,
                anchor: details.globalPosition,
              ),
            ),
        ],
      );
    }
    final tabletMode = adaptiveLayoutClass != AdaptiveLayoutClass.phoneCompact;

    Widget songTile(SongsTableData song) {
      return ListTile(
        leading: SizedBox(
          width: tabletMode
              ? (compactDensity ? 48 : 52)
              : (compactDensity ? 44 : 48),
          height: tabletMode
              ? (compactDensity ? 48 : 52)
              : (compactDensity ? 44 : 48),
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
        dense: compactDensity || !tabletMode,
        visualDensity: compactDensity
            ? const VisualDensity(horizontal: -1, vertical: -2)
            : null,
        contentPadding: EdgeInsets.symmetric(horizontal: tabletMode ? 12 : 8),
        onTap: () => onTap(song),
        onLongPress: () => showSongContextMenu(context, ref, song),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: tabletMode ? 4 : 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final useTwoColumns =
              compactWideLandscapeMode &&
              constraints.maxWidth >= _compactWideTwoColumnMinWidth;
          if (useTwoColumns) {
            return GridView.builder(
              key: const ValueKey<String>('homeSongListTwoColumnGrid'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: songs.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: _compactWideColumnGap,
                mainAxisSpacing: compactDensity ? 2 : 4,
                mainAxisExtent: compactDensity ? 56 : 64,
              ),
              itemBuilder: (context, index) => songTile(songs[index]),
            );
          }
          return Column(
            key: const ValueKey<String>('homeSongListSingleColumn'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final song in songs) songTile(song),
            ],
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

class _HomeActionRow extends ConsumerWidget {
  const _HomeActionRow({required this.variant});

  final _HomeActionRowVariant variant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final listenTogetherEnabled = ref.watch(
      groupListeningSettingsProvider.select((settings) => settings.enabled),
    );
    final likedOnly = ref.watch(homeLikedOnlyFilterProvider);
    final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
    final downloadedSongIds = downloadedOnly
        ? (ref.watch(downloadedSongIdsProvider).asData?.value ??
              const <String>{})
        : const <String>{};
    final likedSongs =
        ref.watch(likedSongsProvider).asData?.value ?? const <SongsTableData>[];
    final likedIds =
        (downloadedOnly
                ? likedSongs.where((s) => downloadedSongIds.contains(s.id))
                : likedSongs)
            .map((s) => s.id)
            .toList(growable: false);

    void toggleLikedOnly() {
      ref.read(homeLikedOnlyFilterProvider.notifier).enabled = !likedOnly;
    }

    void toggleDownloadedOnly() {
      ref.read(downloadedOnlyFilterProvider.notifier).enabled = !downloadedOnly;
    }

    void startInstantRadio() {
      final seedSongId = likedIds[math.Random().nextInt(likedIds.length)];
      ref
          .read(queueProvider.notifier)
          .replace(<String>[seedSongId], autoPlay: true)
          .then((_) async {
            await activatePreferredMixMode(ref, seedSongId: seedSongId);
            ref.read(playerOverlayStackProvider.notifier).expand();
          })
          .ignore();
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
          if (listenTogetherEnabled)
            GroupListeningSessionButton(
              constraints: variant == _HomeActionRowVariant.compactWide
                  ? iconConstraints
                  : null,
            ),
          IconButton(
            tooltip: 'Instant Radio',
            constraints: variant == _HomeActionRowVariant.compactWide
                ? iconConstraints
                : null,
            icon: const Icon(Icons.radio_rounded),
            onPressed: likedIds.isEmpty ? null : startInstantRadio,
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
                if (listenTogetherEnabled) ...<Widget>[
                  GroupListeningSessionButton(
                    variant: GroupListeningSessionButtonVariant.filledTonal,
                    constraints: iconConstraints,
                  ),
                  const SizedBox(width: 8),
                ],
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
                    onPressed: likedIds.isEmpty ? null : startInstantRadio,
                    icon: const Icon(Icons.radio_rounded),
                    label: const Text(
                      'Instant Radio',
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
