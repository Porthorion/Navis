import 'dart:async';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/desktop/desktop_primitives.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/star_sync_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show searchFocusRequestProvider;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/desktop_tokens.dart';

String _formatMiniPlayerDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const double _sideRailWidth = 270;
  final ValueNotifier<double> _playerSheetProgress = ValueNotifier<double>(0);
  bool _didCheckBatteryOptimizationPrompt = false;
  bool Function()? _nowPlayingBackInterceptor;
  bool _compactWideInternalOverlayActive = false;
  VoidCallback? _compactWideQueueRequestHandler;

  // NOTE: We intentionally do NOT use WidgetsBindingObserver.didPopRoute()
  // for back-button handling. That observer fires BEFORE the Navigator
  // processes the event, which means it would consume back presses that
  // should dismiss higher-priority UI first. Instead we let Navigator-owned
  // routes (dialogs, bottom sheets, etc.) handle back normally and only apply
  // shell back behavior when this shell route is actually current.

  @override
  void dispose() {
    _playerSheetProgress.dispose();
    super.dispose();
  }

  void _handleCompactWideOverlayActiveChanged(bool active) {
    if (_compactWideInternalOverlayActive == active || !mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _compactWideInternalOverlayActive == active) {
        return;
      }
      setState(() {
        _compactWideInternalOverlayActive = active;
      });
    });
  }

  void _handleCompactWideQueueRequestChanged(VoidCallback? handler) {
    _compactWideQueueRequestHandler = handler;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didCheckBatteryOptimizationPrompt) {
      return;
    }
    _didCheckBatteryOptimizationPrompt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybePromptForBatteryOptimization());
    });
  }

  Future<void> _maybePromptForBatteryOptimization() async {
    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig == null || ref.read(syncIntervalMinutesProvider) <= 0) {
      return;
    }
    final service = ref.read(batteryOptimizationServiceProvider);
    final shouldPrompt = await service.shouldPromptDisableBatteryOptimization();
    if (!mounted || !shouldPrompt) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) {
        return _BatteryOptimizationSheet(
          onOpenSettings: () {
            Navigator.of(sheetContext).pop();
            unawaited(service.openDisableBatteryOptimizationSettings());
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    ref.watch(librarySyncControllerProvider);
    ref.watch(scrobbleDispatchControllerProvider);
    ref.watch(starSyncDispatchControllerProvider);
    ref.watch(autoDownloadStarredDispatchControllerProvider);

    // Global Instant Mix snackbar / error notifications (shown on any screen).
    ref.listen<InstantMixState>(instantMixProvider, (prev, next) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        messenger.showSnackBar(
          SnackBar(
            content: Text(l10n.nowPlayingInstantMixStarted(count)),
          ),
        );
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

    // Global Smart Queue snackbar / error notifications.
    ref.listen<SmartQueueState>(smartQueueProvider, (prev, next) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.smartQueueStarted(count))),
        );
        ref.read(smartQueueProvider.notifier).clearSnackbar();
      }
      if (next.error != null && next.error != prev?.error) {
        final msg = next.error == SmartQueueError.unsupported
            ? l10n.smartQueueUnsupported
            : l10n.smartQueueError;
        messenger.showSnackBar(SnackBar(content: Text(msg)));
        ref.read(smartQueueProvider.notifier).clearError();
      }
      // Show a "stopped" notification when the session ends.
      if ((prev?.active ?? false) && !next.active && next.error == null) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.smartQueueStopped)),
        );
      }
    });
    // Global Radio stream error snackbar.
    ref.listen<AsyncValue<void>>(radioStreamErrorProvider, (prev, next) {
      if (!mounted) return;
      if (next.hasValue && prev != null && prev.hasValue) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.radioStreamUnavailable),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
    ref.listen<bool>(
      playerStateProvider.select((snapshot) => snapshot.hasActivePlayback),
      (previous, next) {
        if (!next) {
          _playerSheetProgress.value = 0;
          ref.read(playerOverlayStackProvider.notifier).clear();
        }
      },
    );
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
    final currentMediaItem = ref.watch(currentMediaItemProvider).asData?.value;
    final songTitle = playback.isRadioMode
        ? (playback.radioStation!.nowPlayingTitle ??
              playback.radioStation!.stationName)
        : (currentSongAsync.asData?.value?.title ?? currentMediaItem?.title);
    final songArtist = playback.isRadioMode
        ? (playback.radioStation!.nowPlayingArtist ??
              playback.radioStation!.stationName)
        : (currentSongAsync.asData?.value?.artistName ??
              currentMediaItem?.artist);
    final coverArtId = playback.isRadioMode
        ? null
        : currentSongAsync.asData?.value?.coverArt;
    final coverArtUrl = playback.isRadioMode
        ? null
        : currentMediaItem?.artUri?.toString();
    final showPlayer = playback.hasActivePlayback;
    final isExpanded = ref.watch(playerSheetExpandedProvider);
    final showQueueOverlay = ref.watch(queueOverlayVisibleProvider);
    final showLikedLibraryPage = ref.watch(showLikedPageProvider);
    final showArtistsLibraryPage = ref.watch(showArtistsPageProvider);
    final showPlaylistsLibraryPage = ref.watch(showPlaylistsPageProvider);
    final showRadioLibraryPage = ref.watch(showRadioPageProvider);
    final selectedLibrarySection = ref.watch(librarySectionProvider);
    final hasPlayerOverlay = ref.watch(
      playerOverlayStackProvider.select((stack) => stack.isNotEmpty),
    );
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
    final mediaSize = MediaQuery.sizeOf(context);
    final mediaPadding = MediaQuery.paddingOf(context);
    final screenWidth = mediaSize.width;
    final screenHeight = mediaSize.height;
    final safeHorizontalWidth =
        (screenWidth - mediaPadding.left - mediaPadding.right).clamp(
          0.0,
          double.infinity,
        );
    final isPhoneFormFactor = !isDesktopRuntime && mediaSize.shortestSide < 600;
    final useDesktopShell = isDesktopRuntime;
    final desktopLayoutClass = resolveDesktopLayoutClass(screenWidth);
    final adaptiveShellMode = resolveAdaptiveShellMode(
      desktopRuntime: isDesktopRuntime,
      viewportSize: mediaSize,
      safePadding: mediaPadding,
    );
    final useCompactWideLandscape =
        !useDesktopShell &&
        adaptiveShellMode == AdaptiveShellMode.compactWideLandscape;
    final useStandardRailNavigation =
        !useDesktopShell && adaptiveShellMode == AdaptiveShellMode.standardRail;
    final useRailNavigation =
        useStandardRailNavigation || useCompactWideLandscape;
    final desktopTokens = desktopTokensOf(context);
    final desktopSidebarWidth = (screenWidth * 0.25).clamp(
      desktopTokens.sidebarWidth,
      420.0,
    );
    final compactWideSystemInset =
        (mediaPadding.left > mediaPadding.right
                ? mediaPadding.left
                : mediaPadding.right)
            .clamp(0.0, 48.0);
    final compactWideRailInsetBonus = (compactWideSystemInset * 0.3).clamp(
      0.0,
      12.0,
    );
    final sideRailWidth = useCompactWideLandscape
        ? ((((safeHorizontalWidth / 18) * 1.2) + compactWideRailInsetBonus) *
                  1.3)
              .clamp(57.2, 75.4)
        : (isPhoneFormFactor
              ? (screenWidth * 0.22).clamp(188.0, 236.0)
              : (screenWidth * 0.25).clamp(_sideRailWidth, 360.0));
    final showLibrarySubNavigation =
        useStandardRailNavigation && screenWidth >= 840 && !isPhoneFormFactor;
    final allowScrollableRail = !isPhoneFormFactor && !useCompactWideLandscape;
    final useWideMiniPlayerStyle = screenWidth >= 960;
    final compactBottomMiniPlayerHeight = (screenHeight * 0.18).clamp(
      80.0,
      140.0,
    );

    if (useCompactWideLandscape && showQueueOverlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        ref.read(playerOverlayStackProvider.notifier).hideQueue();
      });
    }
    final railDestinations = <_ShellDestination>[
      _ShellDestination(
        icon: Icons.home_outlined,
        label: l10n.navHome,
      ),
      _ShellDestination(
        icon: Icons.library_music_outlined,
        label: l10n.navLibrary,
      ),
      _ShellDestination(
        icon: Icons.search,
        label: l10n.navSearch,
      ),
      _ShellDestination(
        icon: Icons.settings_outlined,
        label: l10n.navSettings,
      ),
    ];

    void onDestinationSelected(int index) {
      NavService.dismissKeyboard(context);
      NavService.clearExitPrompt();
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      if (showQueueOverlay) {
        overlay.hideQueue();
      }
      if (isExpanded) {
        overlay.collapse();
      }
      final branchIndex = visibleBranchIndices[index];
      if (branchIndex == _libraryBranchIndex) {
        ref
            .read(librarySectionProvider.notifier)
            .setSection(
              LibrarySection.albums,
            );
      }
      if (branchIndex == _searchBranchIndex) {
        ref.read(searchFocusRequestProvider.notifier).increment();
      }
      if (branchIndex == _homeBranchIndex &&
          branchIndex == navigationShell.currentIndex) {
        ref.read(homeScrollToTopRequestProvider.notifier).request();
      }
      if (branchIndex == _libraryBranchIndex &&
          branchIndex == navigationShell.currentIndex) {
        ref.read(libraryScrollToTopRequestProvider.notifier).request();
      }
      navigationShell.goBranch(
        branchIndex,
        initialLocation: branchIndex == navigationShell.currentIndex,
      );
    }

    void onLibrarySectionSelected(LibrarySection section) {
      NavService.dismissKeyboard(context);
      NavService.clearExitPrompt();
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      if (showQueueOverlay) {
        overlay.hideQueue();
      }
      if (isExpanded) {
        overlay.collapse();
      }
      final wasSameSection =
          navigationShell.currentIndex == _libraryBranchIndex &&
          selectedLibrarySection == section;
      ref.read(librarySectionProvider.notifier).setSection(section);
      navigationShell.goBranch(_libraryBranchIndex, initialLocation: true);
      if (wasSameSection) {
        ref.read(libraryScrollToTopRequestProvider.notifier).request();
      }
    }

    Future<void> executeDesktopCommand(DesktopCommandAction action) async {
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      switch (action) {
        case DesktopCommandAction.focusSearch:
          onDestinationSelected(2);
          break;
        case DesktopCommandAction.toggleQueue:
          if (!showPlayer) {
            return;
          }
          if (showQueueOverlay) {
            overlay.hideQueue();
          } else {
            overlay.showQueue();
          }
          break;
        case DesktopCommandAction.toggleNowPlaying:
          if (!showPlayer) {
            return;
          }
          if (isExpanded) {
            overlay.collapse();
          } else {
            overlay.expand();
          }
          break;
        case DesktopCommandAction.playPause:
          final handler = ref.read(audioHandlerProvider);
          if (handler == null) {
            return;
          }
          if (playback.playing) {
            await handler.pause();
          } else {
            await handler.play();
          }
          break;
        case DesktopCommandAction.nextTrack:
          final handler = ref.read(audioHandlerProvider);
          if (handler == null) {
            return;
          }
          if (playback.isRadioMode) {
            await handler.stopRadio();
          } else {
            await handler.skipToNext();
          }
          break;
        case DesktopCommandAction.previousTrack:
          if (playback.isRadioMode) {
            return;
          }
          await ref.read(audioHandlerProvider)?.skipToPrevious();
          break;
      }
    }

    final shell = BackButtonListener(
      onBackButtonPressed: () async {
        // Intercept Android back-button presses before nested branch
        // navigators pop their detail routes. This is what gives the shell's
        // overlay stack priority over pages like album detail.
        if (!hasPlayerOverlay || !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return false;
        }
        if (isExpanded && (_nowPlayingBackInterceptor?.call() ?? false)) {
          return true;
        }
        NavService.handleSystemBack(
          ref: ref,
          context: context,
          navigationShell: navigationShell,
          homeBranchIndex: _homeBranchIndex,
        );
        return true;
      },
      child: PopScope(
        // canPop: false means the shell route itself cannot be popped by the
        // Navigator. Shell-managed player overlays are dismissed explicitly in
        // NavService.handleSystemBack, and Navigator-owned modal routes above
        // this shell are ignored by the route-current guard below.
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          // route. Navigator-owned modals above the shell should consume back
          // without also mutating the shell state underneath.
          if (didPop || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
          if (isExpanded && (_nowPlayingBackInterceptor?.call() ?? false)) {
            return;
          }
          NavService.handleSystemBack(
            ref: ref,
            context: context,
            navigationShell: navigationShell,
            homeBranchIndex: _homeBranchIndex,
          );
        },
        child: Scaffold(
          // Keep the expanded player at full height even if a hidden text field
          // elsewhere (e.g. Search) still has keyboard insets in flight.
          resizeToAvoidBottomInset:
              !useCompactWideLandscape && !(showPlayer && isExpanded),
          body: Stack(
            children: <Widget>[
              if (useDesktopShell)
                _DesktopWorkspace(
                  desktopLayoutClass: desktopLayoutClass,
                  sidebarWidth: desktopSidebarWidth,
                  selectedIndex: selectedIndex,
                  destinations: railDestinations,
                  showOfflineBanner: showOfflineBanner,
                  offlineBannerText: l10n.serverOfflineBanner,
                  showPlayer: showPlayer,
                  isExpanded: isExpanded,
                  showQueueOverlay: showQueueOverlay,
                  hasPlayerOverlay: hasPlayerOverlay,
                  navigationShell: navigationShell,
                  playback: playback,
                  songTitle: songTitle,
                  songArtist: songArtist,
                  coverArtId: coverArtId,
                  coverArtUrl: coverArtUrl,
                  onDestinationSelected: onDestinationSelected,
                  showLibrarySubNavigation: showLibrarySubNavigation,
                  selectedLibrarySection: selectedLibrarySection,
                  showLikedLibraryPage: showLikedLibraryPage,
                  showArtistsLibraryPage: showArtistsLibraryPage,
                  showPlaylistsLibraryPage: showPlaylistsLibraryPage,
                  showRadioLibraryPage: showRadioLibraryPage,
                  onLibrarySectionSelected: onLibrarySectionSelected,
                  allowScrollableRail: allowScrollableRail,
                  onOpenPlayer: () {
                    NavService.dismissKeyboard(context);
                    ref.read(playerOverlayStackProvider.notifier).expand();
                  },
                  onCollapsePlayer: () =>
                      ref.read(playerOverlayStackProvider.notifier).collapse(),
                  onToggleQueue: () {
                    final overlay = ref.read(
                      playerOverlayStackProvider.notifier,
                    );
                    if (showQueueOverlay) {
                      overlay.hideQueue();
                    } else {
                      overlay.showQueue();
                    }
                  },
                  onDismissQueue: () =>
                      ref.read(playerOverlayStackProvider.notifier).hideQueue(),
                  onNowPlayingBackInterceptorChanged: (handler) {
                    _nowPlayingBackInterceptor = handler;
                  },
                )
              else if (useRailNavigation)
                Padding(
                  padding: useCompactWideLandscape
                      ? EdgeInsets.only(
                          left: mediaPadding.left,
                          right: mediaPadding.right,
                        )
                      : EdgeInsets.zero,
                  child: Row(
                    children: <Widget>[
                      Material(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                        child: SafeArea(
                          left: !useCompactWideLandscape,
                          right: !useCompactWideLandscape,
                          child: SizedBox(
                            width: sideRailWidth,
                            child: Padding(
                              padding: useCompactWideLandscape
                                  ? const EdgeInsets.fromLTRB(0, 8, 0, 8)
                                  : const EdgeInsets.fromLTRB(18, 14, 18, 14),
                              child: useCompactWideLandscape
                                  ? _CompactIconRail(
                                      destinations: railDestinations,
                                      selectedIndex: selectedIndex,
                                      onDestinationSelected:
                                          onDestinationSelected,
                                    )
                                  : _RailSidebar(
                                      selectedIndex: selectedIndex,
                                      onDestinationSelected:
                                          onDestinationSelected,
                                      destinations: railDestinations,
                                      showLibrarySubNavigation:
                                          showLibrarySubNavigation,
                                      selectedLibrarySection:
                                          selectedLibrarySection,
                                      showLikedLibraryPage:
                                          showLikedLibraryPage,
                                      showArtistsLibraryPage:
                                          showArtistsLibraryPage,
                                      showPlaylistsLibraryPage:
                                          showPlaylistsLibraryPage,
                                      showRadioLibraryPage:
                                          showRadioLibraryPage,
                                      onLibrarySectionSelected:
                                          onLibrarySectionSelected,
                                      allowScrollableRail: allowScrollableRail,
                                      showPlayer: showPlayer,
                                      playback: playback,
                                      songTitle: songTitle,
                                      songArtist: songArtist,
                                      coverArtId: coverArtId,
                                      coverArtUrl: coverArtUrl,
                                      isRadio: playback.isRadioMode,
                                      radioArtUrl: playback
                                          .radioStation
                                          ?.nowPlayingArtUrl,
                                      onOpenPlayer: () {
                                        NavService.dismissKeyboard(context);
                                        ref
                                            .read(
                                              playerOverlayStackProvider
                                                  .notifier,
                                            )
                                            .expand();
                                      },
                                    ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: SafeArea(
                          left: false,
                          top: false,
                          right: false,
                          child: Column(
                            children: <Widget>[
                              if (showOfflineBanner)
                                Material(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.errorContainer,
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
                              Expanded(
                                child: NavigatorPopHandler<Object?>(
                                  enabled: !hasPlayerOverlay,
                                  onPopWithResult: (result) {
                                    final router = GoRouter.of(context);
                                    if (!router.canPop()) {
                                      return;
                                    }
                                    NavService.clearExitPrompt();
                                    router.pop(result);
                                  },
                                  child: useCompactWideLandscape && showPlayer
                                      ? Stack(
                                          children: <Widget>[
                                            // Inset the content area from the
                                            // bottom so the mini player strip
                                            // never covers page content.
                                            AnimatedPositioned(
                                              duration: const Duration(
                                                milliseconds: 280,
                                              ),
                                              curve: Curves.easeOut,
                                              top: 0,
                                              left: 0,
                                              right: 0,
                                              bottom: isExpanded
                                                  ? 0
                                                  : compactBottomMiniPlayerHeight,
                                              child: navigationShell,
                                            ),
                                            Positioned.fill(
                                              child: ExpandablePlayerSheet(
                                                isExpanded: isExpanded,
                                                onExpand: () {
                                                  NavService.dismissKeyboard(
                                                    context,
                                                  );
                                                  ref
                                                      .read(
                                                        playerOverlayStackProvider
                                                            .notifier,
                                                      )
                                                      .expand();
                                                },
                                                onCollapse: () => ref
                                                    .read(
                                                      playerOverlayStackProvider
                                                          .notifier,
                                                    )
                                                    .collapse(),
                                                dragEnabled:
                                                    !_compactWideInternalOverlayActive,
                                                onSwipeUp: () =>
                                                    _compactWideQueueRequestHandler
                                                        ?.call(),
                                                miniPlayer: SizedBox(
                                                  height:
                                                      compactBottomMiniPlayerHeight,
                                                  child: _MiniPlayerStrip(
                                                    playback: playback,
                                                    flattenWideStyle: true,
                                                    compactWideLandscapeMode:
                                                        true,
                                                    enableVerticalExpandGesture:
                                                        false,
                                                    songTitle: songTitle,
                                                    songArtist: songArtist,
                                                    coverArtId: coverArtId,
                                                    coverArtUrl: coverArtUrl,
                                                    isRadio:
                                                        playback.isRadioMode,
                                                    radioArtUrl: playback
                                                        .radioStation
                                                        ?.nowPlayingArtUrl,
                                                    onTap: () {
                                                      NavService.dismissKeyboard(
                                                        context,
                                                      );
                                                      ref
                                                          .read(
                                                            playerOverlayStackProvider
                                                                .notifier,
                                                          )
                                                          .expand();
                                                    },
                                                  ),
                                                ),
                                                fullPlayer: NowPlayingScreen(
                                                  wideEmbeddedMode: true,
                                                  compactWideLandscapeMode:
                                                      useCompactWideLandscape,
                                                  onShowQueue: () =>
                                                      _compactWideQueueRequestHandler
                                                          ?.call(),
                                                  onCollapse: () => ref
                                                      .read(
                                                        playerOverlayStackProvider
                                                            .notifier,
                                                      )
                                                      .collapse(),
                                                  onBackInterceptorChanged:
                                                      (handler) {
                                                        _nowPlayingBackInterceptor =
                                                            handler;
                                                      },
                                                  onCompactWideOverlayActiveChanged:
                                                      _handleCompactWideOverlayActiveChanged,
                                                  onCompactWideQueueRequestChanged:
                                                      _handleCompactWideQueueRequestChanged,
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : showPlayer
                                      ? Stack(
                                          children: <Widget>[
                                            Positioned.fill(
                                              child: navigationShell,
                                            ),
                                            Positioned.fill(
                                              child: IgnorePointer(
                                                ignoring: !isExpanded,
                                                child: AnimatedSlide(
                                                  duration: const Duration(
                                                    milliseconds: 280,
                                                  ),
                                                  curve: Curves.easeOut,
                                                  offset: isExpanded
                                                      ? Offset.zero
                                                      : const Offset(0, 1),
                                                  child: NowPlayingScreen(
                                                    wideEmbeddedMode: true,
                                                    compactWideLandscapeMode:
                                                        useCompactWideLandscape,
                                                    onShowQueue: () =>
                                                        NavService.showQueue(
                                                          context,
                                                          ref,
                                                        ),
                                                    onCollapse: () => ref
                                                        .read(
                                                          playerOverlayStackProvider
                                                              .notifier,
                                                        )
                                                        .collapse(),
                                                    onBackInterceptorChanged:
                                                        (handler) {
                                                          _nowPlayingBackInterceptor =
                                                              handler;
                                                        },
                                                  ),
                                                ),
                                              ),
                                            ),
                                            if (showQueueOverlay)
                                              Positioned.fill(
                                                child: _QueueOverlay(
                                                  fullscreen: true,
                                                  onDismiss: () => ref
                                                      .read(
                                                        playerOverlayStackProvider
                                                            .notifier,
                                                      )
                                                      .hideQueue(),
                                                ),
                                              ),
                                          ],
                                        )
                                      : navigationShell,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
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
                    Expanded(
                      child: NavigatorPopHandler<Object?>(
                        // When a shell-managed player overlay is visible, the
                        // nested branch navigator must not consume system back
                        // before the shell dismisses that overlay.
                        enabled: !hasPlayerOverlay,
                        onPopWithResult: (result) {
                          final router = GoRouter.of(context);
                          if (!router.canPop()) {
                            return;
                          }
                          NavService.clearExitPrompt();
                          router.pop(result);
                        },
                        child: navigationShell,
                      ),
                    ),
                    if (showPlayer && !isExpanded)
                      SizedBox(
                        height: ExpandablePlayerSheet.miniPlayerHeight,
                      ),
                  ],
                ),
              if (showPlayer && !useRailNavigation)
                Positioned.fill(
                  left: 0,
                  child: ExpandablePlayerSheet(
                    isExpanded: isExpanded,
                    onProgressChanged: (value) {
                      final clamped = value.clamp(0.0, 1.0);
                      if ((_playerSheetProgress.value - clamped).abs() >
                          0.001) {
                        _playerSheetProgress.value = clamped;
                      }
                    },
                    onExpand: () {
                      // Dismiss the keyboard (e.g. search bar) before expanding
                      // so the Now Playing screen isn't squished.
                      NavService.dismissKeyboard(context);
                      ref.read(playerOverlayStackProvider.notifier).expand();
                    },
                    onCollapse: () => ref
                        .read(playerOverlayStackProvider.notifier)
                        .collapse(),
                    onSwipeUp: () => NavService.showQueue(context, ref),
                    miniPlayer: useRailNavigation
                        ? const SizedBox.shrink()
                        : _MiniPlayerStrip(
                            playback: playback,
                            flattenWideStyle: useWideMiniPlayerStyle,
                            enableVerticalExpandGesture: false,
                            songTitle: songTitle,
                            songArtist: songArtist,
                            coverArtId: coverArtId,
                            coverArtUrl: coverArtUrl,
                            isRadio: playback.isRadioMode,
                            radioArtUrl:
                                playback.radioStation?.nowPlayingArtUrl,
                            onTap: () {
                              // Dismiss keyboard before expanding.
                              NavService.dismissKeyboard(context);
                              ref
                                  .read(playerOverlayStackProvider.notifier)
                                  .expand();
                            },
                          ),
                    fullPlayer: NowPlayingScreen(
                      onShowQueue: () => NavService.showQueue(context, ref),
                      onCollapse: () => ref
                          .read(playerOverlayStackProvider.notifier)
                          .collapse(),
                      onBackInterceptorChanged: (handler) {
                        _nowPlayingBackInterceptor = handler;
                      },
                    ),
                  ),
                ),
              if (showPlayer && showQueueOverlay && !useRailNavigation)
                Positioned.fill(
                  left: 0,
                  child: _QueueOverlay(
                    fullscreen: useRailNavigation,
                    onDismiss: () => ref
                        .read(playerOverlayStackProvider.notifier)
                        .hideQueue(),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: useRailNavigation
              ? null
              : ValueListenableBuilder<double>(
                  valueListenable: _playerSheetProgress,
                  builder: (context, progress, _) {
                    final reveal = showPlayer
                        ? (1 - progress).clamp(0.0, 1.0)
                        : 1.0;

                    return _BottomNavReveal(
                      reveal: reveal,
                      child: NavigationBar(
                        selectedIndex: selectedIndex,
                        labelBehavior:
                            NavigationDestinationLabelBehavior.alwaysHide,
                        onDestinationSelected: onDestinationSelected,
                        destinations: <NavigationDestination>[
                          NavigationDestination(
                            icon: Icon(railDestinations[0].icon),
                            label: railDestinations[0].label,
                          ),
                          NavigationDestination(
                            icon: Icon(railDestinations[1].icon),
                            label: railDestinations[1].label,
                          ),
                          NavigationDestination(
                            icon: Icon(railDestinations[2].icon),
                            label: railDestinations[2].label,
                          ),
                          NavigationDestination(
                            icon: Icon(railDestinations[3].icon),
                            label: railDestinations[3].label,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
    if (!useDesktopShell) {
      return shell;
    }
    return Shortcuts(
      shortcuts: buildDesktopShortcutMap(Theme.of(context).platform),
      child: Actions(
        actions: <Type, Action<Intent>>{
          DesktopCommandIntent: DesktopCommandActionHandler(
            context: context,
            executor: executeDesktopCommand,
          ),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Focus(
            autofocus: true,
            child: shell,
          ),
        ),
      ),
    );
  }
}

class _BatteryOptimizationSheet extends StatelessWidget {
  const _BatteryOptimizationSheet({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.battery_saver_outlined,
              color: colors.primary,
              size: 28,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Keep background sync alive',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Battery optimization is still enabled for Navis. '
            'Disabling it helps background sync finish reliably without the '
            'system shutting the app down early.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.sync_outlined,
                  color: colors.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Recommended if you rely on automatic library scans.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Later'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open settings'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BottomNavReveal extends StatelessWidget {
  const _BottomNavReveal({
    required this.reveal,
    required this.child,
  });

  final double reveal;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clamped = reveal.clamp(0.0, 1.0);
    if (clamped <= 0.001) {
      return const SizedBox.shrink();
    }

    final opacity = Curves.easeOut.transform(clamped);
    final slideOffset = (1 - clamped) * 24;

    return IgnorePointer(
      ignoring: clamped < 0.98,
      child: ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: clamped,
          child: Transform.translate(
            offset: Offset(0, slideOffset),
            child: Opacity(
              opacity: opacity,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopWorkspace extends StatelessWidget {
  const _DesktopWorkspace({
    required this.desktopLayoutClass,
    required this.sidebarWidth,
    required this.selectedIndex,
    required this.destinations,
    required this.showOfflineBanner,
    required this.offlineBannerText,
    required this.showPlayer,
    required this.isExpanded,
    required this.showQueueOverlay,
    required this.hasPlayerOverlay,
    required this.navigationShell,
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.onDestinationSelected,
    required this.showLibrarySubNavigation,
    required this.allowScrollableRail,
    required this.selectedLibrarySection,
    required this.showLikedLibraryPage,
    required this.showArtistsLibraryPage,
    required this.showPlaylistsLibraryPage,
    required this.showRadioLibraryPage,
    required this.onLibrarySectionSelected,
    required this.onOpenPlayer,
    required this.onCollapsePlayer,
    required this.onToggleQueue,
    required this.onDismissQueue,
    required this.onNowPlayingBackInterceptorChanged,
  });

  final DesktopLayoutClass desktopLayoutClass;
  final double sidebarWidth;
  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final bool showOfflineBanner;
  final String offlineBannerText;
  final bool showPlayer;
  final bool isExpanded;
  final bool showQueueOverlay;
  final bool hasPlayerOverlay;
  final StatefulNavigationShell navigationShell;
  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final ValueChanged<int> onDestinationSelected;
  final bool showLibrarySubNavigation;
  final bool allowScrollableRail;
  final LibrarySection selectedLibrarySection;
  final bool showLikedLibraryPage;
  final bool showArtistsLibraryPage;
  final bool showPlaylistsLibraryPage;
  final bool showRadioLibraryPage;
  final ValueChanged<LibrarySection> onLibrarySectionSelected;
  final VoidCallback onOpenPlayer;
  final VoidCallback onCollapsePlayer;
  final VoidCallback onToggleQueue;
  final VoidCallback onDismissQueue;
  final ValueChanged<bool Function()?> onNowPlayingBackInterceptorChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Material(
          color: colors.surfaceContainerLowest,
          child: SafeArea(
            child: SizedBox(
              width: sidebarWidth,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: _RailSidebar(
                  selectedIndex: selectedIndex,
                  onDestinationSelected: onDestinationSelected,
                  destinations: destinations,
                  showLibrarySubNavigation: showLibrarySubNavigation,
                  allowScrollableRail: allowScrollableRail,
                  selectedLibrarySection: selectedLibrarySection,
                  showLikedLibraryPage: showLikedLibraryPage,
                  showArtistsLibraryPage: showArtistsLibraryPage,
                  showPlaylistsLibraryPage: showPlaylistsLibraryPage,
                  showRadioLibraryPage: showRadioLibraryPage,
                  onLibrarySectionSelected: onLibrarySectionSelected,
                  showPlayer: false,
                  playback: playback,
                  songTitle: songTitle,
                  songArtist: songArtist,
                  coverArtId: coverArtId,
                  coverArtUrl: coverArtUrl,
                  isRadio: playback.isRadioMode,
                  radioArtUrl: playback.radioStation?.nowPlayingArtUrl,
                  onOpenPlayer: onOpenPlayer,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: SafeArea(
            left: false,
            top: false,
            right: false,
            child: Column(
              children: <Widget>[
                if (showOfflineBanner)
                  Material(
                    color: colors.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            Icons.cloud_off_outlined,
                            color: colors.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              offlineBannerText,
                              style: TextStyle(color: colors.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: DesktopFrame(
                    layoutClass: desktopLayoutClass,
                    child: NavigatorPopHandler<Object?>(
                      enabled: !hasPlayerOverlay,
                      onPopWithResult: (result) {
                        final router = GoRouter.of(context);
                        if (!router.canPop()) {
                          return;
                        }
                        NavService.clearExitPrompt();
                        router.pop(result);
                      },
                      child: Stack(
                        children: <Widget>[
                          Positioned.fill(child: navigationShell),
                          if (showPlayer && isExpanded)
                            Positioned.fill(
                              child: NowPlayingScreen(
                                wideEmbeddedMode: true,
                                onShowQueue: onToggleQueue,
                                onCollapse: onCollapsePlayer,
                                onBackInterceptorChanged:
                                    onNowPlayingBackInterceptorChanged,
                              ),
                            ),
                          if (showPlayer && showQueueOverlay)
                            Positioned.fill(
                              child: _QueueOverlay(
                                fullscreen: true,
                                onDismiss: onDismissQueue,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (showPlayer && !isExpanded)
                  _DesktopPlayerBar(
                    playback: playback,
                    songTitle: songTitle,
                    songArtist: songArtist,
                    coverArtId: coverArtId,
                    coverArtUrl: coverArtUrl,
                    onOpenPlayer: onOpenPlayer,
                    onToggleQueue: onToggleQueue,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopPlayerBar extends ConsumerWidget {
  const _DesktopPlayerBar({
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.onOpenPlayer,
    required this.onToggleQueue,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final VoidCallback onOpenPlayer;
  final VoidCallback onToggleQueue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final isPlaying = playback.playing;
    final title = (songTitle == null || songTitle!.trim().isEmpty)
        ? l10n.miniPlayerUnknownTrack
        : songTitle!;
    final artist = (songArtist == null || songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : songArtist!;

    return Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 84,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: <Widget>[
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onOpenPlayer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    child: Row(
                      children: <Widget>[
                        if (coverArtId == null || coverArtId!.trim().isEmpty)
                          _MiniRemoteArt(
                            artUrl: coverArtUrl,
                            colorScheme: colors,
                          )
                        else
                          CoverArtImage(
                            coverArtId: coverArtId,
                            size: 200,
                            width: 52,
                            height: 52,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: l10n.nowPlayingPrevious,
                  onPressed: playback.isRadioMode
                      ? null
                      : () {
                          ref.read(audioHandlerProvider)?.skipToPrevious();
                        },
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
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
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                  label: Text(
                    isPlaying ? l10n.miniPlayerPause : l10n.miniPlayerPlay,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: playback.isRadioMode
                      ? l10n.radioStopStation
                      : l10n.miniPlayerSkipNext,
                  onPressed: () async {
                    final handler = ref.read(audioHandlerProvider);
                    if (handler == null) {
                      return;
                    }
                    if (playback.isRadioMode) {
                      await handler.stopRadio();
                    } else {
                      await handler.skipToNext();
                    }
                  },
                  icon: Icon(
                    playback.isRadioMode
                        ? Icons.stop_rounded
                        : Icons.skip_next_rounded,
                  ),
                ),
                const SizedBox(width: 18),
                IconButton(
                  tooltip: l10n.queueTitle,
                  onPressed: onToggleQueue,
                  icon: const Icon(Icons.queue_music_outlined),
                ),
                IconButton(
                  tooltip: l10n.nowPlayingTitle,
                  onPressed: onOpenPlayer,
                  icon: const Icon(Icons.open_in_full),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueOverlay extends StatefulWidget {
  const _QueueOverlay({
    required this.onDismiss,
    this.fullscreen = false,
  });

  final VoidCallback onDismiss;
  final bool fullscreen;

  @override
  State<_QueueOverlay> createState() => _QueueOverlayState();
}

class _QueueOverlayState extends State<_QueueOverlay>
    with SingleTickerProviderStateMixin {
  static const double _sheetHeightFactor = 0.95;
  static const Duration _closeDuration = Duration(milliseconds: 220);
  static const double _flingVelocityThreshold = 300;
  static const double _scrollDismissDistance = 96;
  static const Duration _scrollPullSettleDelay = Duration(milliseconds: 150);

  late final AnimationController _controller;

  // Scroll controller shared with the queue list so we know when the list
  // is at the top and a downward drag should move the sheet instead.
  final ScrollController _scrollController = ScrollController();

  // Raw-pointer drag tracking — uses Listener (not GestureDetector) so it
  // fires alongside the list's scroll recognizer without competing in the
  // gesture arena.
  VelocityTracker? _velocityTracker;
  int? _activePointer;
  bool _draggingSheet = false;
  bool _dismissing = false;
  bool _queueReorderActive = false;
  double _scrollPullDistance = 0;
  Timer? _scrollPullSettleTimer;

  // Cumulative displacement tracking — distinguishes horizontal swipes
  // (e.g. Dismissible swipe-to-delete) from vertical sheet drags.
  double _cumulativeDx = 0;
  double _cumulativeDy = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: _closeDuration,
    );
    // Open with a spring fling — matches the player sheet's feel.
    _controller.fling(velocity: 2.5);
  }

  @override
  void dispose() {
    _scrollPullSettleTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissing) return;
    _scrollPullSettleTimer?.cancel();
    _dismissing = true;
    _controller.fling(velocity: -2.5).whenComplete(widget.onDismiss);
  }

  void _setDraggingSheet(bool value) {
    if (_draggingSheet == value || !mounted) {
      _draggingSheet = value;
      return;
    }
    setState(() => _draggingSheet = value);
  }

  void _setQueueReorderActive(bool value) {
    if (_queueReorderActive == value) return;
    if (!mounted) {
      _queueReorderActive = value;
      return;
    }
    setState(() => _queueReorderActive = value);

    // Lock sheet-dismiss gestures while list reordering is active.
    if (value) {
      _activePointer = null;
      _velocityTracker = null;
      _resetScrollPull(animateBack: true);
      _setDraggingSheet(false);
    }
  }

  void _resetScrollPull({bool animateBack = false}) {
    _scrollPullSettleTimer?.cancel();
    _scrollPullDistance = 0;
    if (animateBack && !_dismissing && _controller.value < 0.999) {
      _controller.fling(velocity: 2.5);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _dismissing ||
        _queueReorderActive ||
        _draggingSheet) {
      return;
    }
    final dy = event.scrollDelta.dy;
    if (dy >= -1) {
      if (_scrollPullDistance > 0) {
        _resetScrollPull(animateBack: true);
      }
      return;
    }

    final atTop =
        !_scrollController.hasClients || _scrollController.offset <= 0.0;
    if (!atTop) {
      return;
    }

    final effectiveHeightFactor = widget.fullscreen ? 1.0 : _sheetHeightFactor;
    final sheetHeight =
        MediaQuery.of(context).size.height * effectiveHeightFactor;
    final dragDistance = -dy;
    _scrollPullDistance += dragDistance;
    _controller.value = (_controller.value - dragDistance / sheetHeight).clamp(
      0.0,
      1.0,
    );

    if (_scrollPullDistance >= _scrollDismissDistance ||
        _controller.value < 0.72) {
      _dismiss();
      return;
    }

    _scrollPullSettleTimer?.cancel();
    _scrollPullSettleTimer = Timer(_scrollPullSettleDelay, () {
      if (!mounted || _dismissing || _queueReorderActive || _draggingSheet) {
        return;
      }
      _resetScrollPull(animateBack: true);
    });
  }

  // ---- Raw pointer handlers -----------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (_dismissing || _queueReorderActive) return;
    _activePointer = event.pointer;
    _velocityTracker = VelocityTracker.withKind(event.kind);
    _velocityTracker!.addPosition(event.timeStamp, event.position);
    _resetScrollPull();
    _setDraggingSheet(false);
    _cumulativeDx = 0.0;
    _cumulativeDy = 0.0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dismissing || _queueReorderActive || event.pointer != _activePointer) {
      return;
    }
    _velocityTracker?.addPosition(event.timeStamp, event.position);

    final dx = event.delta.dx;
    final dy = event.delta.dy;

    _cumulativeDx += dx.abs();
    _cumulativeDy += dy.abs();

    if (!_draggingSheet) {
      // Capture the sheet only when the list is already at the top and the
      // gesture is clearly vertical. Once captured, keep control until
      // pointer-up so the user can reverse direction mid-swipe.
      if (_cumulativeDx > _cumulativeDy * 1.5 && _cumulativeDx > 10) {
        // Horizontal movement dominates — let the child handle it.
        return;
      }
      if (dy <= 0) {
        return;
      }
      final atTop =
          !_scrollController.hasClients || _scrollController.offset <= 0.0;
      if (!atTop) return;
      _setDraggingSheet(true);
    }

    final effectiveHeightFactor = widget.fullscreen ? 1.0 : _sheetHeightFactor;
    final sheetHeight =
        MediaQuery.of(context).size.height * effectiveHeightFactor;
    _controller.value = (_controller.value - dy / sheetHeight).clamp(0.0, 1.0);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (_queueReorderActive) return;
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _resetScrollPull();
    final wasDragging = _draggingSheet;
    _setDraggingSheet(false);
    if (_dismissing || !wasDragging) return;

    final velocity = _velocityTracker?.getVelocity().pixelsPerSecond.dy ?? 0.0;
    if (velocity > _flingVelocityThreshold || _controller.value < 0.7) {
      _dismiss();
    } else {
      _controller.fling(velocity: 2.5);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_queueReorderActive) return;
    if (event.pointer != _activePointer) return;
    _activePointer = null;
    _resetScrollPull();
    final wasDragging = _draggingSheet;
    _setDraggingSheet(false);
    if (_dismissing) return;
    // If the sheet was being dragged and is already partially down, dismiss.
    if (wasDragging && _controller.value < 0.85) {
      _dismiss();
    } else if (_controller.value < 0.99) {
      _controller.fling(velocity: 2.5);
    }
  }

  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final progress = _controller.value;
        final heightFactor = widget.fullscreen ? 1.0 : _sheetHeightFactor;

        final queueContent = widget.fullscreen
            ? Material(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  child: QueueSheet(
                    scrollController: _scrollController,
                    sheetDragActive: _draggingSheet,
                    onReorderDragChanged: _setQueueReorderActive,
                    onClose: _dismiss,
                  ),
                ),
              )
            : QueueSheet(
                scrollController: _scrollController,
                sheetDragActive: _draggingSheet,
                onReorderDragChanged: _setQueueReorderActive,
                onClose: _dismiss,
              );

        return Stack(
          children: <Widget>[
            if (!widget.fullscreen)
              // Scrim — fades in/out with the sheet; tap to dismiss.
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: progress < 0.01,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _dismiss,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: progress * 0.45),
                    ),
                  ),
                ),
              ),
            // Sheet — slides up from the bottom with 1:1 finger tracking.
            Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                heightFactor: heightFactor,
                widthFactor: 1,
                child: FractionalTranslation(
                  translation: Offset(0, 1 - progress),
                  child: IgnorePointer(
                    ignoring: _dismissing,
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _onPointerDown,
                      onPointerMove: _onPointerMove,
                      onPointerUp: _onPointerUp,
                      onPointerCancel: _onPointerCancel,
                      onPointerSignal: _onPointerSignal,
                      child: queueContent,
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

const int _homeBranchIndex = 0;
const int _libraryBranchIndex = 1;
const int _searchBranchIndex = 2;
const int _settingsBranchIndex = 3;

class _ShellDestination {
  const _ShellDestination({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class _CompactIconRail extends StatelessWidget {
  const _CompactIconRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<_ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = destinations.length;
        final hitTargetWidth = constraints.maxWidth;
        // Keep rail width 20% wider than icon width in compact landscape.
        final iconSize = ((hitTargetWidth / 1.2) * 0.8).clamp(22.4, 38.4);

        return Column(
          mainAxisSize: MainAxisSize.max,
          children: <Widget>[
            for (var i = 0; i < count; i++)
              Expanded(
                child: SizedBox(
                  width: hitTargetWidth,
                  height: double.infinity,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onDestinationSelected(i),
                    child: Center(
                      child: Icon(
                        destinations[i].icon,
                        size: iconSize,
                        color: i == selectedIndex
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
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

class _RailSidebar extends ConsumerWidget {
  const _RailSidebar({
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.showLibrarySubNavigation,
    this.allowScrollableRail = true,
    required this.selectedLibrarySection,
    required this.showLikedLibraryPage,
    required this.showArtistsLibraryPage,
    required this.showPlaylistsLibraryPage,
    required this.showRadioLibraryPage,
    required this.onLibrarySectionSelected,
    required this.showPlayer,
    required this.playback,
    required this.onOpenPlayer,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
    this.coverArtUrl,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final List<_ShellDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final bool showLibrarySubNavigation;
  final bool allowScrollableRail;
  final LibrarySection selectedLibrarySection;
  final bool showLikedLibraryPage;
  final bool showArtistsLibraryPage;
  final bool showPlaylistsLibraryPage;
  final bool showRadioLibraryPage;
  final ValueChanged<LibrarySection> onLibrarySectionSelected;
  final bool showPlayer;
  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isRadio;
  final String? radioArtUrl;
  final VoidCallback onOpenPlayer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const navTileEstimatedHeight = 64.0;
                const subNavTileEstimatedHeight = 44.0;
                const subNavTrailingGap = 6.0;
                const reservedMiniPlayerHeight = 170.0;
                const railMiniPlayerGap = 6.0;
                const railCutoffSlack = 4.0;
                final librarySubSectionCount =
                    1 +
                    (showLikedLibraryPage ? 1 : 0) +
                    (showArtistsLibraryPage ? 1 : 0) +
                    (showPlaylistsLibraryPage ? 1 : 0) +
                    (showRadioLibraryPage ? 1 : 0);
                final navViewportHeight =
                    (constraints.maxHeight -
                            (showPlayer
                                ? (reservedMiniPlayerHeight + railMiniPlayerGap)
                                : 0.0))
                        .clamp(0.0, double.infinity);
                final baseNavHeight =
                    destinations.length * navTileEstimatedHeight;
                final inlineLibraryNavHeight =
                    baseNavHeight +
                    (librarySubSectionCount * subNavTileEstimatedHeight) +
                    subNavTrailingGap;
                final showLibrarySectionsInline =
                    showLibrarySubNavigation &&
                    navViewportHeight >=
                        (inlineLibraryNavHeight + railCutoffSlack);
                final useScrollableRail =
                    allowScrollableRail &&
                    navViewportHeight < (baseNavHeight + railCutoffSlack);

                final navTiles = <Widget>[
                  for (var i = 0; i < destinations.length; i++) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _RailNavTile(
                        key: ValueKey('railNavTile-$i'),
                        destination: destinations[i],
                        selected: i == selectedIndex,
                        onTap: () => onDestinationSelected(i),
                      ),
                    ),
                    if (showLibrarySectionsInline && i == 1) ...<Widget>[
                      _RailSubNavTile(
                        key: const ValueKey<String>(
                          'railLibrarySection-albums',
                        ),
                        label: AppLocalizations.of(context)!.libraryTabAlbums,
                        selected:
                            selectedIndex == 1 &&
                            selectedLibrarySection == LibrarySection.albums,
                        onTap: () =>
                            onLibrarySectionSelected(LibrarySection.albums),
                      ),
                      if (showLikedLibraryPage)
                        _RailSubNavTile(
                          key: const ValueKey<String>(
                            'railLibrarySection-liked',
                          ),
                          label: AppLocalizations.of(context)!.libraryTabLiked,
                          selected:
                              selectedIndex == 1 &&
                              selectedLibrarySection == LibrarySection.liked,
                          onTap: () => onLibrarySectionSelected(
                            LibrarySection.liked,
                          ),
                        ),
                      if (showArtistsLibraryPage)
                        _RailSubNavTile(
                          key: const ValueKey<String>(
                            'railLibrarySection-artists',
                          ),
                          label: AppLocalizations.of(
                            context,
                          )!.libraryTabArtists,
                          selected:
                              selectedIndex == 1 &&
                              selectedLibrarySection == LibrarySection.artists,
                          onTap: () => onLibrarySectionSelected(
                            LibrarySection.artists,
                          ),
                        ),
                      if (showPlaylistsLibraryPage)
                        _RailSubNavTile(
                          key: const ValueKey<String>(
                            'railLibrarySection-playlists',
                          ),
                          label: AppLocalizations.of(context)!.navPlaylists,
                          selected:
                              selectedIndex == 1 &&
                              selectedLibrarySection ==
                                  LibrarySection.playlists,
                          onTap: () => onLibrarySectionSelected(
                            LibrarySection.playlists,
                          ),
                        ),
                      if (showRadioLibraryPage)
                        _RailSubNavTile(
                          key: const ValueKey<String>(
                            'railLibrarySection-radio',
                          ),
                          label: AppLocalizations.of(context)!.navRadio,
                          selected:
                              selectedIndex == 1 &&
                              selectedLibrarySection == LibrarySection.radio,
                          onTap: () =>
                              onLibrarySectionSelected(LibrarySection.radio),
                        ),
                      const SizedBox(height: 6),
                    ],
                  ],
                ];

                final player = showPlayer
                    ? _RailMiniPlayer(
                        playback: playback,
                        songTitle: songTitle,
                        songArtist: songArtist,
                        coverArtId: coverArtId,
                        coverArtUrl: coverArtUrl,
                        isRadio: isRadio,
                        radioArtUrl: radioArtUrl,
                        onOpenPlayer: onOpenPlayer,
                      )
                    : const SizedBox.shrink();

                final navRegion = useScrollableRail
                    ? SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: navTiles,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          ...navTiles,
                          const Spacer(),
                        ],
                      );

                if (!showPlayer) {
                  return navRegion;
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: navRegion),
                    const SizedBox(height: 6),
                    player,
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _RailNavTile extends StatelessWidget {
  const _RailNavTile({
    super.key,
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      color: selected
          ? colorScheme.onSecondaryContainer
          : colorScheme.onSurfaceVariant,
    );

    return Material(
      color: selected
          ? colorScheme.secondaryContainer.withValues(alpha: 0.9)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Icon(
                destination.icon,
                size: 24,
                color: selected
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  destination.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailSubNavTile extends StatelessWidget {
  const _RailSubNavTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 6, bottom: 6),
      child: Material(
        color: selected
            ? colorScheme.primaryContainer.withValues(alpha: 0.35)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
        ),
      ),
    );
  }
}

class _RailMiniPlayer extends ConsumerStatefulWidget {
  const _RailMiniPlayer({
    required this.playback,
    required this.onOpenPlayer,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
    this.coverArtUrl,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onOpenPlayer;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isRadio;
  final String? radioArtUrl;

  @override
  ConsumerState<_RailMiniPlayer> createState() => _RailMiniPlayerState();
}

class _RailMiniPlayerState extends ConsumerState<_RailMiniPlayer> {
  double? _dragSliderValue;
  bool _isSeeking = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final playback = widget.playback;
    final isPlaying = playback.playing;
    final position = playback.position;
    final duration = playback.duration;
    final durationMs = duration.inMilliseconds;
    final canSeek = !widget.isRadio && durationMs > 0;
    final sliderMax = canSeek ? durationMs.toDouble() : 1.0;
    final positionMs = canSeek
        ? position.inMilliseconds.clamp(0, durationMs).toDouble()
        : 0.0;
    final sliderValue = canSeek
        ? ((_dragSliderValue ?? positionMs).clamp(0.0, sliderMax))
        : 0.0;
    final seekPreviewPosition = Duration(milliseconds: sliderValue.round());
    final progress = duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    const compactButtonConstraints = BoxConstraints(
      minWidth: 46,
      minHeight: 46,
    );

    final fullMiniPlayer = Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 12, 6, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onOpenPlayer,
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              if (widget.isRadio)
                                _MiniRadioArt(
                                  artUrl: widget.radioArtUrl,
                                  colorScheme: cs,
                                  size: 44,
                                )
                              else if (widget.coverArtId == null ||
                                  widget.coverArtId!.trim().isEmpty)
                                _MiniRemoteArt(
                                  artUrl: widget.coverArtUrl,
                                  colorScheme: cs,
                                  size: 44,
                                )
                              else
                                CoverArtImage(
                                  coverArtId: widget.coverArtId,
                                  size: 300,
                                  width: 44,
                                  height: 44,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      (widget.songTitle == null ||
                                              widget.songTitle!.trim().isEmpty)
                                          ? l10n.miniPlayerUnknownTrack
                                          : widget.songTitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      softWrap: false,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 17,
                                            height: 1.15,
                                          ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      (widget.songArtist == null ||
                                              widget.songArtist!.trim().isEmpty)
                                          ? l10n.miniPlayerUnknownArtist
                                          : widget.songArtist!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            color: cs.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: <Widget>[
                              IconButton(
                                tooltip: l10n.nowPlayingPrevious,
                                constraints: compactButtonConstraints,
                                padding: EdgeInsets.zero,
                                iconSize: 24,
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.isRadio
                                    ? null
                                    : () {
                                        unawaited(
                                          HapticFeedback.lightImpact(),
                                        );
                                        unawaited(
                                          ref
                                              .read(audioHandlerProvider)
                                              ?.skipToPrevious(),
                                        );
                                      },
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              IconButton(
                                tooltip: isPlaying
                                    ? l10n.miniPlayerPause
                                    : l10n.miniPlayerPlay,
                                constraints: compactButtonConstraints,
                                style: IconButton.styleFrom(
                                  backgroundColor: cs.primaryContainer,
                                  foregroundColor: cs.onPrimaryContainer,
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(46, 46),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: () async {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
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
                                ),
                              ),
                              IconButton(
                                tooltip: widget.isRadio
                                    ? l10n.radioStopStation
                                    : l10n.miniPlayerSkipNext,
                                constraints: compactButtonConstraints,
                                padding: EdgeInsets.zero,
                                iconSize: 24,
                                visualDensity: VisualDensity.compact,
                                onPressed: () async {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  unawaited(HapticFeedback.lightImpact());
                                  if (widget.isRadio) {
                                    await handler.stopRadio();
                                  } else {
                                    unawaited(handler.skipToNext());
                                  }
                                },
                                icon: Icon(
                                  widget.isRadio
                                      ? Icons.stop_rounded
                                      : Icons.skip_next_rounded,
                                ),
                              ),
                              IconButton(
                                tooltip: playback.isCurrentSongLiked
                                    ? l10n.actionLiked
                                    : l10n.actionLike,
                                constraints: compactButtonConstraints,
                                padding: EdgeInsets.zero,
                                iconSize: 24,
                                visualDensity: VisualDensity.compact,
                                onPressed: widget.isRadio
                                    ? null
                                    : () {
                                        unawaited(
                                          HapticFeedback.lightImpact(),
                                        );
                                        unawaited(
                                          ref
                                              .read(audioHandlerProvider)
                                              ?.toggleLike(),
                                        );
                                      },
                                icon: Icon(
                                  playback.isCurrentSongLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: playback.isCurrentSongLiked
                                      ? cs.primary
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 120),
                          curve: Curves.easeOut,
                          opacity: _isSeeking && canSeek ? 1 : 0,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: BackdropFilter(
                              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                              child: Container(
                                color: cs.surface.withValues(alpha: 0.24),
                                alignment: Alignment.center,
                                child: Text(
                                  '${_formatMiniPlayerDuration(seekPreviewPosition)} / '
                                  '${_formatMiniPlayerDuration(duration)}',
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (canSeek)
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  value: sliderValue,
                  max: sliderMax,
                  onChangeStart: (value) {
                    setState(() {
                      _isSeeking = true;
                      _dragSliderValue = value;
                    });
                  },
                  onChanged: (value) {
                    setState(() => _dragSliderValue = value);
                  },
                  onChangeEnd: (value) {
                    setState(() {
                      _isSeeking = false;
                      _dragSliderValue = null;
                    });
                    unawaited(
                      ref
                          .read(audioHandlerProvider)
                          ?.seek(Duration(milliseconds: value.round())),
                    );
                  },
                ),
              )
            else
              LinearProgressIndicator(
                value: widget.isRadio
                    ? (playback.processingState ==
                                  AudioProcessingState.loading ||
                              playback.processingState ==
                                  AudioProcessingState.buffering
                          ? null
                          : 0.0)
                    : progress,
                minHeight: 3,
                color: cs.primary,
                backgroundColor: cs.primary.withValues(alpha: 0.12),
              ),
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final tightHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight < 150;
        if (!tightHeight) {
          return fullMiniPlayer;
        }
        return ClipRect(
          child: SingleChildScrollView(
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 150),
              child: fullMiniPlayer,
            ),
          ),
        );
      },
    );
  }
}

class _MiniPlayerStrip extends ConsumerStatefulWidget {
  const _MiniPlayerStrip({
    required this.playback,
    required this.onTap,
    this.flattenWideStyle = false,
    this.compactWideLandscapeMode = false,
    this.enableVerticalExpandGesture = true,
    this.songTitle,
    this.songArtist,
    this.coverArtId,
    this.coverArtUrl,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onTap;
  final bool flattenWideStyle;
  final bool compactWideLandscapeMode;
  final bool enableVerticalExpandGesture;
  final String? songTitle;
  final String? songArtist;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isRadio;
  final String? radioArtUrl;

  @override
  ConsumerState<_MiniPlayerStrip> createState() => _MiniPlayerStripState();
}

class _MiniPlayerStripState extends ConsumerState<_MiniPlayerStrip> {
  static const double _expandSwipeDistance = 56;
  double _verticalDragDistance = 0;
  bool _expandedFromDrag = false;

  void _resetVerticalDragState() {
    _verticalDragDistance = 0;
    _expandedFromDrag = false;
  }

  void _triggerExpandFromDrag() {
    if (_expandedFromDrag) {
      return;
    }
    _expandedFromDrag = true;
    HapticFeedback.selectionClick();
    widget.onTap();
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    _resetVerticalDragState();
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (_expandedFromDrag) {
      return;
    }
    final delta = details.primaryDelta;
    if (delta == null) {
      return;
    }
    _verticalDragDistance += delta;
    if (_verticalDragDistance <= -_expandSwipeDistance) {
      _triggerExpandFromDrag();
    }
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    if (!_expandedFromDrag) {
      final velocity = details.primaryVelocity ?? 0;
      if (velocity < -220 || _verticalDragDistance <= -_expandSwipeDistance) {
        _triggerExpandFromDrag();
      }
    }
    _resetVerticalDragState();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playback;
    final onTap = widget.onTap;
    final flattenWideStyle = widget.flattenWideStyle;
    final compactWideLandscapeMode = widget.compactWideLandscapeMode;
    final enableVerticalExpandGesture = widget.enableVerticalExpandGesture;
    final songTitle = widget.songTitle;
    final songArtist = widget.songArtist;
    final coverArtId = widget.coverArtId;
    final coverArtUrl = widget.coverArtUrl;
    final isRadio = widget.isRadio;
    final radioArtUrl = widget.radioArtUrl;

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final compactControls = viewportWidth < 380;
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
      onVerticalDragStart: enableVerticalExpandGesture
          ? _handleVerticalDragStart
          : null,
      onVerticalDragUpdate: enableVerticalExpandGesture
          ? _handleVerticalDragUpdate
          : null,
      onVerticalDragEnd: enableVerticalExpandGesture
          ? _handleVerticalDragEnd
          : null,
      onVerticalDragCancel: enableVerticalExpandGesture
          ? _resetVerticalDragState
          : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: (flattenWideStyle && !compactWideLandscapeMode)
              ? null
              : Border(
                  top: BorderSide(
                    color: cs.outlineVariant.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
        ),
        child: Material(
          color: compactWideLandscapeMode
              ? cs.surfaceContainerHigh
              : (flattenWideStyle
                    ? Colors.transparent
                    : cs.surfaceContainerHigh),
          child: InkWell(
            onTap: onTap,
            child: compactWideLandscapeMode
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                    child: Row(
                      children: <Widget>[
                        if (isRadio)
                          _MiniRadioArt(artUrl: radioArtUrl, colorScheme: cs)
                        else if (coverArtId == null ||
                            coverArtId.trim().isEmpty)
                          _MiniRemoteArt(artUrl: coverArtUrl, colorScheme: cs)
                        else
                          CoverArtImage(
                            coverArtId: coverArtId,
                            size: 240,
                            width: 48,
                            height: 48,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                (songTitle == null || songTitle.trim().isEmpty)
                                    ? l10n.miniPlayerUnknownTrack
                                    : songTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                (songArtist == null ||
                                        songArtist.trim().isEmpty)
                                    ? l10n.miniPlayerUnknownArtist
                                    : songArtist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: cs.onSurface.withValues(
                                        alpha: 0.58,
                                      ),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.nowPlayingPrevious,
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              final handler = ref.read(audioHandlerProvider);
                              if (handler == null) {
                                return;
                              }
                              HapticFeedback.lightImpact();
                              handler.skipToPrevious();
                            },
                            icon: const Icon(
                              Icons.skip_previous_rounded,
                              size: 20,
                            ),
                          ),
                        IconButton(
                          tooltip: isPlaying
                              ? l10n.miniPlayerPause
                              : l10n.miniPlayerPlay,
                          style: IconButton.styleFrom(
                            backgroundColor: cs.primaryContainer,
                            foregroundColor: cs.onPrimaryContainer,
                            minimumSize: const Size(40, 40),
                            padding: const EdgeInsets.all(5),
                            visualDensity: VisualDensity.compact,
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
                            size: 21,
                          ),
                        ),
                        if (!isRadio)
                          IconButton(
                            tooltip: l10n.miniPlayerSkipNext,
                            visualDensity: VisualDensity.compact,
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
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              final handler = ref.read(audioHandlerProvider);
                              if (handler == null) {
                                return;
                              }
                              await handler.stopRadio();
                            },
                            icon: const Icon(Icons.stop_rounded, size: 20),
                          ),
                        if (!isRadio)
                          IconButton(
                            tooltip: playback.isCurrentSongLiked
                                ? l10n.actionLiked
                                : l10n.actionLike,
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              HapticFeedback.lightImpact();
                              ref.read(audioHandlerProvider)?.toggleLike();
                            },
                            icon: Icon(
                              playback.isCurrentSongLiked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 20,
                              color: playback.isCurrentSongLiked
                                  ? cs.primary
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  )
                : Column(
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
                            if (isRadio)
                              _MiniRadioArt(
                                artUrl: radioArtUrl,
                                colorScheme: cs,
                              )
                            else if (coverArtId == null ||
                                coverArtId.trim().isEmpty)
                              _MiniRemoteArt(
                                artUrl: coverArtUrl,
                                colorScheme: cs,
                              )
                            else
                              CoverArtImage(
                                coverArtId: coverArtId,
                                size: 200,
                                width: 48,
                                height: 48,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    (songTitle == null ||
                                            songTitle.trim().isEmpty)
                                        ? l10n.miniPlayerUnknownTrack
                                        : songTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    (songArtist == null ||
                                            songArtist.trim().isEmpty)
                                        ? l10n.miniPlayerUnknownArtist
                                        : songArtist,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          color: cs.onSurface.withValues(
                                            alpha: 0.6,
                                          ),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isRadio)
                              IconButton(
                                tooltip: l10n.nowPlayingPrevious,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  HapticFeedback.lightImpact();
                                  handler.skipToPrevious();
                                },
                                icon: const Icon(
                                  Icons.skip_previous_rounded,
                                  size: 19,
                                ),
                              ),
                            IconButton(
                              tooltip: isPlaying
                                  ? l10n.miniPlayerPause
                                  : l10n.miniPlayerPlay,
                              style: IconButton.styleFrom(
                                backgroundColor: cs.primaryContainer,
                                foregroundColor: cs.onPrimaryContainer,
                                minimumSize: Size(
                                  compactControls ? 40 : 46,
                                  compactControls ? 40 : 46,
                                ),
                                padding: const EdgeInsets.all(6),
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
                            if (!isRadio)
                              IconButton(
                                tooltip: l10n.miniPlayerSkipNext,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  HapticFeedback.lightImpact();
                                  handler.skipToNext();
                                },
                                icon: const Icon(
                                  Icons.skip_next_rounded,
                                  size: 19,
                                ),
                              )
                            else
                              IconButton(
                                tooltip: l10n.radioStopStation,
                                constraints: const BoxConstraints(),
                                padding: const EdgeInsets.fromLTRB(4, 6, 6, 6),
                                onPressed: () async {
                                  final handler = ref.read(
                                    audioHandlerProvider,
                                  );
                                  if (handler == null) {
                                    return;
                                  }
                                  await handler.stopRadio();
                                },
                                icon: const Icon(Icons.stop_rounded, size: 20),
                              ),
                            if (!isRadio)
                              IconButton(
                                tooltip: playback.isCurrentSongLiked
                                    ? l10n.actionLiked
                                    : l10n.actionLike,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: () {
                                  HapticFeedback.lightImpact();
                                  ref.read(audioHandlerProvider)?.toggleLike();
                                },
                                icon: Icon(
                                  playback.isCurrentSongLiked
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  size: 19,
                                  color: playback.isCurrentSongLiked
                                      ? cs.primary
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                            SizedBox(width: compactControls ? 0 : 4),
                          ],
                        ),
                      ),
                      if (!flattenWideStyle)
                        LinearProgressIndicator(
                          value: isRadio
                              ? (playback.processingState ==
                                            AudioProcessingState.loading ||
                                        playback.processingState ==
                                            AudioProcessingState.buffering
                                    ? null
                                    : 0.0)
                              : progress,
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
    this.size = 48,
  });

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: colorScheme.primaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.radio,
        size: size * 0.5,
        color: colorScheme.onPrimaryContainer,
      ),
    );
  }
}

/// Remote/non-library fallback cover art in the mini player.
class _MiniRemoteArt extends StatelessWidget {
  const _MiniRemoteArt({
    required this.artUrl,
    required this.colorScheme,
    this.size = 48,
  });

  final String? artUrl;
  final ColorScheme colorScheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _placeholder(),
            )
          : _placeholder(),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      color: colorScheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.music_note,
        size: size * 0.5,
        color: colorScheme.onSecondaryContainer,
      ),
    );
  }
}
