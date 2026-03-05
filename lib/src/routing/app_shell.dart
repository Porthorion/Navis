import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
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

class _AppShellState extends ConsumerState<AppShell> {
  final ValueNotifier<double> _playerSheetProgress = ValueNotifier<double>(0);
  bool _didCheckBatteryOptimizationPrompt = false;

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
    final showPlayer = playback.hasActivePlayback;
    final isExpanded = ref.watch(playerSheetExpandedProvider);
    final showQueueOverlay = ref.watch(queueOverlayVisibleProvider);
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

    return BackButtonListener(
      onBackButtonPressed: () async {
        // Intercept Android back-button presses before nested branch
        // navigators pop their detail routes. This is what gives the shell's
        // overlay stack priority over pages like album detail.
        if (!hasPlayerOverlay || !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return false;
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
          // Only run shell fallback logic when this route is the visible top
          // route. Navigator-owned modals above the shell should consume back
          // without also mutating the shell state underneath.
          if (didPop || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
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
          resizeToAvoidBottomInset: !(showPlayer && isExpanded),
          body: Stack(
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
              if (showPlayer)
                Positioned.fill(
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
                      onTap: () {
                        // Dismiss keyboard before expanding.
                        NavService.dismissKeyboard(context);
                        ref.read(playerOverlayStackProvider.notifier).expand();
                      },
                    ),
                    fullPlayer: NowPlayingScreen(
                      onCollapse: () => ref
                          .read(playerOverlayStackProvider.notifier)
                          .collapse(),
                    ),
                  ),
                ),
              if (showPlayer && showQueueOverlay)
                Positioned.fill(
                  child: _QueueOverlay(
                    onDismiss: () => ref
                        .read(playerOverlayStackProvider.notifier)
                        .hideQueue(),
                  ),
                ),
            ],
          ),
          bottomNavigationBar: ValueListenableBuilder<double>(
            valueListenable: _playerSheetProgress,
            builder: (context, progress, _) {
              final reveal = showPlayer ? (1 - progress).clamp(0.0, 1.0) : 1.0;

              return _BottomNavReveal(
                reveal: reveal,
                child: NavigationBar(
                  selectedIndex: selectedIndex,
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysHide,
                  onDestinationSelected: (index) {
                    NavService.dismissKeyboard(context);
                    NavService.clearExitPrompt();
                    final branchIndex = visibleBranchIndices[index];
                    // Trigger focus request whenever the Search tab is tapped.
                    if (branchIndex == _searchBranchIndex) {
                      ref.read(searchFocusRequestProvider.notifier).increment();
                    }
                    // Scroll to top when Library is tapped while already on Library.
                    if (branchIndex == _libraryBranchIndex &&
                        branchIndex == navigationShell.currentIndex) {
                      ref
                          .read(libraryScrollToTopRequestProvider.notifier)
                          .request();
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
              );
            },
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

class _QueueOverlay extends StatefulWidget {
  const _QueueOverlay({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  State<_QueueOverlay> createState() => _QueueOverlayState();
}

class _QueueOverlayState extends State<_QueueOverlay>
    with SingleTickerProviderStateMixin {
  static const double _sheetHeightFactor = 0.95;
  static const Duration _closeDuration = Duration(milliseconds: 280);
  static const double _flingVelocityThreshold = 300.0;

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

  // Cumulative displacement tracking — distinguishes horizontal swipes
  // (e.g. Dismissible swipe-to-delete) from vertical sheet drags.
  double _cumulativeDx = 0.0;
  double _cumulativeDy = 0.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: _closeDuration,
    );
    // Open with a spring fling — matches the player sheet's feel.
    _controller.fling(velocity: 2.5);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissing) return;
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

  // ---- Raw pointer handlers -----------------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (_dismissing) return;
    _activePointer = event.pointer;
    _velocityTracker = VelocityTracker.withKind(event.kind);
    _velocityTracker!.addPosition(event.timeStamp, event.position);
    _setDraggingSheet(false);
    _cumulativeDx = 0.0;
    _cumulativeDy = 0.0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (_dismissing || event.pointer != _activePointer) return;
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

    final sheetHeight = MediaQuery.of(context).size.height * _sheetHeightFactor;
    _controller.value = (_controller.value - dy / sheetHeight).clamp(0.0, 1.0);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointer) return;
    _activePointer = null;
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
    if (event.pointer != _activePointer) return;
    _activePointer = null;
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
        return Stack(
          children: <Widget>[
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
                heightFactor: _sheetHeightFactor,
                widthFactor: 1.0,
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
                      child: QueueSheet(
                        scrollController: _scrollController,
                        sheetDragActive: _draggingSheet,
                        onClose: _dismiss,
                      ),
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
                              (songArtist == null || songArtist!.trim().isEmpty)
                                  ? l10n.miniPlayerUnknownArtist
                                  : songArtist!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  Theme.of(
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
                          minimumSize: const Size(48, 48),
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
  });

  final String? artUrl;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final url = artUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: url != null && url.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: url,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _placeholder(),
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
