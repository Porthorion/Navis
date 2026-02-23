import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(librarySyncControllerProvider);
    ref.watch(scrobbleDispatchControllerProvider);
    final isAuthenticated =
        ref.watch(serverConfigStateProvider).asData?.value != null;
    final reachability = ref.watch(serverReachabilityControllerProvider);
    final showOfflineBanner =
        isAuthenticated &&
        reachability.status == ServerReachabilityStatus.offline;
    final playback = ref.watch(playerStateProvider);
    final currentSongId = playback.currentSongId;
    final currentSongAsync = currentSongId == null
        ? const AsyncValue.data(null)
        : ref.watch(songByIdProvider(currentSongId));
    final showPlayer = playback.queueSongIds.isNotEmpty;
    final isExpanded = ref.watch(playerSheetExpandedProvider);
    final visibleBranchIndices = <int>[
      _homeBranchIndex,
      _libraryBranchIndex,
      _searchBranchIndex,
      _playlistsBranchIndex,
      _settingsBranchIndex,
    ];
    final selectedVisibleIndex = visibleBranchIndices.indexOf(
      navigationShell.currentIndex,
    );
    final selectedIndex = selectedVisibleIndex >= 0 ? selectedVisibleIndex : 0;

    return PopScope(
      canPop: !isExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && isExpanded) {
          ref.read(playerSheetExpandedProvider.notifier).collapse();
        }
      },
      child: Scaffold(
        body: Column(
          children: <Widget>[
            if (showOfflineBanner)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.cloud_off_outlined,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          l10n.serverOfflineBanner,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Expanded(child: navigationShell),
            if (showPlayer)
              ExpandablePlayerSheet(
                isExpanded: isExpanded,
                onExpand: () =>
                    ref.read(playerSheetExpandedProvider.notifier).expand(),
                onCollapse: () =>
                    ref.read(playerSheetExpandedProvider.notifier).collapse(),
                onSwipeUpFullPlayer: () => context.go('/queue'),
                miniPlayer: _MiniPlayerStrip(
                  playback: playback,
                  songTitle: currentSongAsync.asData?.value?.title,
                  songArtist: currentSongAsync.asData?.value?.artistName,
                  coverArtId: currentSongAsync.asData?.value?.coverArt,
                  onTap: () =>
                      ref.read(playerSheetExpandedProvider.notifier).expand(),
                ),
                fullPlayer: NowPlayingScreen(
                  onCollapse: () =>
                      ref.read(playerSheetExpandedProvider.notifier).collapse(),
                  onOpenQueue: () => context.go('/queue'),
                ),
              ),
          ],
        ),
        bottomNavigationBar: showPlayer && isExpanded
            ? null
            : NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: (index) {
                  final branchIndex = visibleBranchIndices[index];
                  navigationShell.goBranch(
                    branchIndex,
                    initialLocation:
                        branchIndex == navigationShell.currentIndex,
                  );
                },
                destinations: <NavigationDestination>[
                  NavigationDestination(
                    icon: const Icon(Icons.home_outlined),
                    label: l10n.navHome,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.library_music_outlined),
                    label: l10n.navLibrary,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.search),
                    label: l10n.navSearch,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.queue_music_outlined),
                    label: l10n.navPlaylists,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    label: l10n.navSettings,
                  ),
                ],
              ),
      ),
    );
  }
}

const int _homeBranchIndex = 0;
const int _libraryBranchIndex = 1;
const int _searchBranchIndex = 2;
const int _playlistsBranchIndex = 3;
const int _settingsBranchIndex = 4;

class _MiniPlayerStrip extends ConsumerWidget {
  const _MiniPlayerStrip({
    required this.playback,
    required this.onTap,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onTap;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;
    final position = playback.position;
    final duration = playback.duration;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 300) {
          return;
        }
        final handler = ref.read(audioHandlerProvider);
        if (handler == null) {
          return;
        }
        if (velocity < 0) {
          handler.skipToNext();
        } else {
          handler.skipToPrevious();
        }
      },
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  children: <Widget>[
                    CoverArtImage(
                      coverArtId: coverArtId,
                      size: 200,
                      width: 40,
                      height: 40,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            (songTitle == null || songTitle!.trim().isEmpty)
                                ? l10n.miniPlayerUnknownTrack
                                : songTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            (songArtist == null || songArtist!.trim().isEmpty)
                                ? l10n.miniPlayerUnknownArtist
                                : songArtist!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: isPlaying
                          ? l10n.miniPlayerPause
                          : l10n.miniPlayerPlay,
                      onPressed: () async {
                        final handler = ref.read(audioHandlerProvider);
                        if (handler == null) {
                          return;
                        }
                        if (isPlaying) {
                          await handler.pause();
                        } else {
                          await handler.play();
                        }
                      },
                      icon: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            LinearProgressIndicator(
              value: progress,
              minHeight: 2,
              backgroundColor: Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }
}
