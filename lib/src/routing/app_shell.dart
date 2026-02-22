import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
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
    final showMiniPlayer = playback.queueSongIds.isNotEmpty;
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

    return Scaffold(
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
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(child: navigationShell),
          if (showMiniPlayer)
            _MiniPlayerStrip(
              playback: playback,
              songTitle: currentSongAsync.asData?.value?.title,
              songArtist: currentSongAsync.asData?.value?.artistName,
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          final branchIndex = visibleBranchIndices[index];
          navigationShell.goBranch(
            branchIndex,
            initialLocation: branchIndex == navigationShell.currentIndex,
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
    this.songTitle,
    this.songArtist,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPlaying = playback.playing;

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              onTap: () => context.go('/now-playing'),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
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
            ),
          ),
          IconButton(
            tooltip: isPlaying ? l10n.miniPlayerPause : l10n.miniPlayerPlay,
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
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
          ),
        ],
      ),
    );
  }
}
