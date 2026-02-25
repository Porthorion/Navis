import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show searchFocusRequestProvider;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/navigation_service.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Intercept the system back gesture / button **before** GoRouter processes
  /// it.  This ensures the expanded player sheet is collapsed before the
  /// router pops a sub-route inside a branch (e.g. album detail).
  @override
  Future<bool> didPopRoute() async {
    final isExpanded = ref.read(playerSheetExpandedProvider);
    if (isExpanded) {
      ref.read(playerSheetExpandedProvider.notifier).collapse();
      return true; // consumed — don't let the router navigate.
    }
    return super.didPopRoute();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(librarySyncControllerProvider);
    ref.watch(scrobbleDispatchControllerProvider);

    // Global Instant Mix snackbar / error notifications (shown on any screen).
    ref.listen<InstantMixState>(instantMixProvider, (prev, next) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        messenger.showSnackBar(SnackBar(
          content: Text(l10n.nowPlayingInstantMixStarted(count)),
        ));
        ref.read(instantMixProvider.notifier).clearSnackbar();
      }
      if (next.error != null && next.error != prev?.error) {
        final msg = next.error == InstantMixError.unsupported
            ? l10n.nowPlayingInstantMixUnsupported
            : l10n.nowPlayingInstantMixError;
        messenger.showSnackBar(SnackBar(content: Text(msg)));
        ref.read(instantMixProvider.notifier).clearError();
      }
    });
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
    final showPlayer = playback.hasActivePlayback;
    final isExpanded = ref.watch(playerSheetExpandedProvider);
    final navigationShell = widget.navigationShell;
    final visibleBranchIndices = <int>[
      _homeBranchIndex,
      _libraryBranchIndex,
      _searchBranchIndex,
      _settingsBranchIndex,
    ];
    final selectedVisibleIndex = visibleBranchIndices.indexOf(
      navigationShell.currentIndex,
    );
    final selectedIndex = selectedVisibleIndex >= 0 ? selectedVisibleIndex : 0;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        NavService.handleSystemBack(
          ref: ref,
          context: context,
          isPlayerExpanded: isExpanded,
          navigationShell: navigationShell,
          homeBranchIndex: _homeBranchIndex,
        );
      },
      child: Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) {
            final bodyHeight = constraints.maxHeight;

            return Stack(
              children: <Widget>[
                Column(
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
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
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
                    if (showPlayer && !isExpanded)
                      SizedBox(
                        height: ExpandablePlayerSheet.miniPlayerHeight,
                      ),
                  ],
                ),
                if (showPlayer)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ExpandablePlayerSheet(
                      maxHeight: bodyHeight,
                      isExpanded: isExpanded,
                      onExpand: () => ref
                          .read(playerSheetExpandedProvider.notifier)
                          .expand(),
                      onCollapse: () => ref
                          .read(playerSheetExpandedProvider.notifier)
                          .collapse(),
                      onSwipeUp: () => NavService.showQueue(context),
                      miniPlayer: _MiniPlayerStrip(
                        playback: playback,
                        songTitle: playback.isRadioMode
                            ? (playback.radioStation!.nowPlayingTitle ??
                                  playback.radioStation!.stationName)
                            : currentSongAsync.asData?.value?.title,
                        songArtist: playback.isRadioMode
                            ? (playback.radioStation!.nowPlayingArtist ??
                                  playback.radioStation!.stationName)
                            : currentSongAsync.asData?.value?.artistName,
                        coverArtId: playback.isRadioMode
                            ? null
                            : currentSongAsync.asData?.value?.coverArt,
                        isRadio: playback.isRadioMode,
                        radioArtUrl: playback.radioStation?.nowPlayingArtUrl,
                        onTap: () => ref
                            .read(playerSheetExpandedProvider.notifier)
                            .expand(),
                      ),
                      fullPlayer: NowPlayingScreen(
                        onCollapse: () => ref
                            .read(playerSheetExpandedProvider.notifier)
                            .collapse(),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        bottomNavigationBar: showPlayer && isExpanded
            ? null
            : NavigationBar(
                selectedIndex: selectedIndex,
                labelBehavior:
                    NavigationDestinationLabelBehavior.alwaysHide,
                onDestinationSelected: (index) {
                  final branchIndex = visibleBranchIndices[index];
                  // Trigger focus request whenever the Search tab is tapped.
                  if (branchIndex == _searchBranchIndex) {
                    ref.read(searchFocusRequestProvider.notifier).increment();
                  }
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
const int _settingsBranchIndex = 3;

class _MiniPlayerStrip extends ConsumerWidget {
  const _MiniPlayerStrip({
    required this.playback,
    required this.onTap,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onTap;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final bool isRadio;
  final String? radioArtUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isPlaying = playback.playing;
    final position = playback.position;
    final duration = playback.duration;
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return GestureDetector(
      onHorizontalDragEnd: isRadio
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() < 300) {
                return;
              }
              final handler = ref.read(audioHandlerProvider);
              if (handler == null) {
                return;
              }
              if (velocity < 0) {
                HapticFeedback.mediumImpact();
                handler.skipToNext();
              } else {
                HapticFeedback.mediumImpact();
                handler.skipToPrevious();
              }
            },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: cs.outlineVariant.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
        ),
        child: Material(
          color: cs.surfaceContainerHigh,
          child: InkWell(
            onTap: onTap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(
                    left: 12,
                    right: 4,
                    top: 7,
                    bottom: 6,
                  ),
                  child: Row(
                    children: <Widget>[
                      // ── Cover art ───────────────────────────────────────────
                      if (isRadio)
                        _MiniRadioArt(artUrl: radioArtUrl, colorScheme: cs)
                      else
                        CoverArtImage(
                          coverArtId: coverArtId,
                          size: 200,
                          width: 48,
                          height: 48,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      const SizedBox(width: 12),
                      // ── Title + artist ──────────────────────────────────────
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
                            const SizedBox(height: 2),
                            Text(
                              (songArtist == null ||
                                      songArtist!.trim().isEmpty)
                                  ? l10n.miniPlayerUnknownArtist
                                  : songArtist!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ── Play / Pause ─────────────────────────────────────────
                      IconButton(
                        tooltip: isPlaying
                            ? l10n.miniPlayerPause
                            : l10n.miniPlayerPlay,
                        style: IconButton.styleFrom(
                          backgroundColor: cs.primaryContainer,
                          foregroundColor: cs.onPrimaryContainer,
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.all(6),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
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
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 22,
                        ),
                      ),
                      // ── Skip next (song) / Stop (radio) ──────────────────────
                      if (!isRadio)
                        IconButton(
                          tooltip: l10n.miniPlayerSkipNext,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                          onPressed: () {
                            final handler = ref.read(audioHandlerProvider);
                            if (handler == null) {
                              return;
                            }
                            HapticFeedback.lightImpact();
                            handler.skipToNext();
                          },
                          icon: const Icon(Icons.skip_next_rounded, size: 20),
                        )
                      else
                        IconButton(
                          tooltip: l10n.radioStopStation,
                          constraints: const BoxConstraints(),
                          padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                          onPressed: () async {
                            final handler = ref.read(audioHandlerProvider);
                            if (handler == null) {
                              return;
                            }
                            await handler.stopRadio();
                          },
                          icon: const Icon(Icons.stop_rounded, size: 20),
                        ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                // ── Progress bar ─────────────────────────────────────────────
                LinearProgressIndicator(
                  value: isRadio && isPlaying ? null : progress,
                  minHeight: 3,
                  color: cs.primary,
                  backgroundColor: cs.primary.withValues(alpha: 0.12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small square cover art for a radio station in the mini player.
class _MiniRadioArt extends StatelessWidget {
  const _MiniRadioArt({
    required this.artUrl,
    required this.colorScheme,
  });

  final String? artUrl;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url != null && url.isNotEmpty
          ? Image.network(
              url,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: 48,
      height: 48,
      color: colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(Icons.radio, color: colorScheme.onPrimaryContainer),
    );
  }
}
