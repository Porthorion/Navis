import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audio_service/audio_service.dart'
    show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/home_activity_scope.dart';
import 'package:navis/src/routing/library_section_navigation_scope.dart';
import 'package:navis/src/common_widgets/desktop_playback_progress.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/src/common_widgets/remote_source_indicator.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/mix_mode_reconciliation_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_sheet.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/now_playing_lyrics_screen.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';
import 'package:navis/src/features/player/presentation/normal_playback_metadata_navigation.dart';
import 'package:navis/src/features/player/presentation/playback_seek_bar_style.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_panel.dart';
import 'package:navis/src/features/player/presentation/playback_quick_actions.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/common_widgets/navis_tooltip.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/queue_screen.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/player/presentation/listenbrainz_feedback_dispatch_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/player/presentation/queue_shuffle_controls.dart';
import 'package:navis/src/features/library/presentation/star_sync_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/navis_tokens.dart';
import 'package:navis/src/theme/motion_policy.dart';
import 'package:navis/src/utils/artist_utils.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:navis/src/utils/song_id_utils.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

part 'app_shell_support_widgets.dart';
part 'app_shell_quick_search_overlay.dart';
part 'app_shell_desktop_workspace.dart';
part 'app_shell_desktop_player_bar.dart';
part 'app_shell_queue_overlay.dart';
part 'app_shell_navigation_widgets.dart';
part 'app_shell_mini_player.dart';
part 'app_shell_desktop_lyrics_overlay.dart';
part 'app_shell_desktop_mini_player.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const double _sideRailWidth = 270;
  static const int _kQueueCoverArtPrefetchAheadCount = 6;
  bool _playbackRecoverySheetOpen = false;
  static const int _kQueueCoverArtPrefetchSizePx = kCoverArtStandardSize;
  static const int _kQueueCoverArtPrefetchDedupeCap = 320;
  final ValueNotifier<double> _playerSheetProgress = ValueNotifier<double>(0);
  final AppNoticeController _appNoticeController = AppNoticeController();
  final Set<String> _queueCoverArtPrefetchedKeys = <String>{};
  final ListQueue<String> _queueCoverArtPrefetchedOrder = ListQueue<String>();
  final GlobalKey<_QueueOverlayState> _queueOverlayKey =
      GlobalKey<_QueueOverlayState>();
  final FocusNode _shellFocusNode = FocusNode(debugLabel: 'appShellRoot');
  final FocusNode _desktopQueueToggleFocusNode = FocusNode(
    debugLabel: 'desktopQueueToggle',
  );
  final TextEditingController _quickSearchController = TextEditingController();
  final FocusNode _quickSearchFocusNode = FocusNode(
    debugLabel: 'desktopQuickSearch',
  );
  bool _didCheckBatteryOptimizationPrompt = false;
  GoRouter? _router;
  // The last Desktop View size; the hidden workspace keeps it in Mini Player.
  Size? _lastDesktopViewSize;
  bool Function()? _nowPlayingBackInterceptor;
  bool _compactWideInternalOverlayActive = false;
  VoidCallback? _compactWideQueueRequestHandler;
  String? _lastNowPlayingVisualPrewarmKey;
  String? _lastNowPlayingLyricsPrewarmSongId;
  FocusNode? _queueReturnFocusNode;
  bool _restoreQueueFocusOnDismiss = false;
  bool _showQuickSearchOverlay = false;
  Timer? _queueCoverArtPrefetchDebounce;
  int _queueCoverArtPrefetchToken = 0;
  bool _globalKeyHandlerInstalled = false;
  Future<void> Function(DesktopCommandAction)? _executeDesktopCommand;
  final ValueNotifier<int> _navExpandRequestNotifier = ValueNotifier<int>(0);
  // Whether the Library section links fit the sidebar; reported by the
  // sidebar after layout and read by the Library page.
  final ValueNotifier<bool> _librarySectionsFitSidebar = ValueNotifier<bool>(
    true,
  );
  // Cached so the global HardwareKeyboard handler can read it outside build().
  // `AdaptiveInputPolicyScope` is a *descendant* of this widget, so
  // `context.dependOnInheritedWidgetOfExactType` cannot see it — caching is
  // the only correct approach.
  AdaptiveInputPolicy? _cachedInputPolicy;
  Size? _lastReportedDesktopViewport;
  late final ProviderSubscription<AppNoticeDiagnosticsCommand?>
  _noticeDiagnosticsSubscription;

  // NOTE: We intentionally do NOT use WidgetsBindingObserver.didPopRoute()
  // for back-button handling. That observer fires BEFORE the Navigator
  // processes the event, which means it would consume back presses that
  // should dismiss higher-priority UI first. Instead we let Navigator-owned
  // routes (dialogs, bottom sheets, etc.) handle back normally and only apply
  // shell back behavior when this shell route is actually current.

  @override
  void initState() {
    super.initState();
    _noticeDiagnosticsSubscription = ref
        .listenManual<AppNoticeDiagnosticsCommand?>(
          appNoticeDiagnosticsProvider,
          (previous, next) {
            if (!mounted || next == null) {
              return;
            }
            _appNoticeController.show(message: next.message, level: next.level);
          },
          fireImmediately: true,
        );
  }

  @override
  void dispose() {
    _router?.routerDelegate.removeListener(_syncLibrarySectionFromLocation);
    _noticeDiagnosticsSubscription.close();
    _removeGlobalKeyHandler();
    _queueCoverArtPrefetchDebounce?.cancel();
    _quickSearchController.dispose();
    _quickSearchFocusNode.dispose();
    _shellFocusNode.dispose();
    _desktopQueueToggleFocusNode.dispose();
    _appNoticeController.dispose();
    _playerSheetProgress.dispose();
    _navExpandRequestNotifier.dispose();
    _librarySectionsFitSidebar.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Global hardware-keyboard handler
  // ---------------------------------------------------------------------------

  void _installGlobalKeyHandler() {
    if (_globalKeyHandlerInstalled) return;
    HardwareKeyboard.instance.addHandler(_onGlobalKeyEvent);
    _globalKeyHandlerInstalled = true;
  }

  void _removeGlobalKeyHandler() {
    if (!_globalKeyHandlerInstalled) return;
    HardwareKeyboard.instance.removeHandler(_onGlobalKeyEvent);
    _globalKeyHandlerInstalled = false;
  }

  bool _dismissNowPlayingInternalOverlayIfExpanded() {
    if (!ref.read(playerSheetExpandedProvider)) {
      return false;
    }
    return _nowPlayingBackInterceptor?.call() ?? false;
  }

  /// Dismisses the top-most transient shell surface: quick search, then the
  /// queue, then a panel inside Now Playing.
  ///
  /// Back and Escape both start here so they close surfaces in the same
  /// order. Returns whether a surface consumed the request.
  bool _dismissTopShellSurface() {
    if (_showQuickSearchOverlay) {
      AppLogger.debug('[ACP_INPUT] dismiss top surface: quick-search');
      _closeQuickSearchOverlay();
      return true;
    }
    if (ref.read(queueOverlayVisibleProvider)) {
      final dismissing = _queueOverlayKey.currentState?.isDismissing ?? false;
      AppLogger.debug(
        '[ACP_INPUT] dismiss top surface: queue (dismissing=$dismissing)',
      );
      if (!dismissing) {
        _hideQueueWithAnimation();
      }
      return true;
    }
    if (_dismissNowPlayingInternalOverlayIfExpanded()) {
      AppLogger.debug('[ACP_INPUT] dismiss top surface: now-playing panel');
      return true;
    }
    return false;
  }

  /// Follows the Library location's `section` into [librarySectionProvider],
  /// so history, deep links and diagnostics select the section they name.
  ///
  /// Runs from the router's change notification, never during build. A
  /// Library location without a section keeps the current one.
  void _syncLibrarySectionFromLocation() {
    final router = _router;
    if (router == null || !mounted) {
      return;
    }
    final section = NavService.librarySectionForLocation(router.state.uri);
    if (section != null && ref.read(librarySectionProvider) != section) {
      ref.read(librarySectionProvider.notifier).setSection(section);
    }
  }

  /// Desktop commands that act on pages or shell panels.
  static const _pageCommands = <DesktopCommandAction>{
    DesktopCommandAction.focusSearch,
    DesktopCommandAction.openQuickSearch,
    DesktopCommandAction.toggleQueue,
    DesktopCommandAction.goHome,
    DesktopCommandAction.goLibrary,
    DesktopCommandAction.goSearch,
    DesktopCommandAction.goSettings,
    DesktopCommandAction.navigateBack,
    DesktopCommandAction.navigateForward,
  };

  /// The shell's system back handler, shared by every back entry point.
  ///
  /// Closes the top-most shell surface first, then defers to
  /// [NavService.handleSystemBack] for Now Playing, page pops, the Home tab
  /// and double-back exit.
  void _handleShellBack() {
    if (_dismissTopShellSurface()) {
      NavService.clearExitPrompt();
      return;
    }
    NavService.handleSystemBack(
      ref: ref,
      context: context,
      navigationShell: widget.navigationShell,
      noticeController: _appNoticeController,
    );
  }

  /// The single global key-event handler that replaces the previous
  /// `Shortcuts` / `Actions` / `onKeyEvent` widget-tree wiring.
  ///
  /// It fires regardless of which widget has focus, making shortcuts reliable
  /// across all views, dialogs, and overlays.
  bool _onGlobalKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    final platform = Theme.of(context).platform;
    final policy = _cachedInputPolicy;
    final enableShortcuts = policy?.enableDesktopCommandShortcuts ?? false;
    final enableEsc = policy?.enableEscapeOverlayPriority ?? false;

    if (!enableShortcuts && !enableEsc) return false;

    final bindings = ref.read(desktopShortcutBindingsProvider);
    final action = matchAnyDesktopCommandForKeyEvent(
      event,
      platform,
      enableShortcuts: enableShortcuts,
      enableEscapeOverlay: enableEsc,
      shortcutBindings: bindings,
    );
    if (action == null) return false;

    // Block transport commands when the user is typing in a text field.
    if (isTextSensitiveDesktopCommand(action) &&
        desktopCommandBlockedByTextInput()) {
      return false;
    }

    // Block transport commands while the library type-to-filter overlay is
    // visible so that e.g. Space doesn't trigger play/pause mid-filter.
    if (isTextSensitiveDesktopCommand(action) &&
        ref.read(libraryTypeFilterActiveProvider)) {
      return false;
    }

    AppLogger.debug('[ACP_INPUT] global key handler matched ${action.name}');
    final executor = _executeDesktopCommand;
    if (executor == null) return false;
    unawaited(executor(action));
    return true;
  }

  void _scheduleQueueCoverArtPrefetch() {
    _queueCoverArtPrefetchDebounce?.cancel();
    final token = ++_queueCoverArtPrefetchToken;
    _queueCoverArtPrefetchDebounce = Timer(
      const Duration(milliseconds: 180),
      () {
        unawaited(_prefetchUpcomingQueueCoverArt(token: token));
      },
    );
  }

  Future<void> _prefetchUpcomingQueueCoverArt({required int token}) async {
    if (!mounted || token != _queueCoverArtPrefetchToken) {
      return;
    }

    final snapshot = ref.read(playerStateProvider);
    if (snapshot.isRadioMode || snapshot.queueSongIds.isEmpty) {
      return;
    }
    if (ref.read(networkTypeProvider) == NetworkType.cellular) {
      return;
    }

    final api = ref.read(subsonicApiProvider);
    if (api == null) {
      return;
    }

    final queueSongIds = snapshot.queueSongIds;
    final rawStartIndex = snapshot.currentIndex ?? 0;
    final startIndex = rawStartIndex < 0
        ? 0
        : (rawStartIndex >= queueSongIds.length
              ? queueSongIds.length - 1
              : rawStartIndex);
    final endExclusive = math.min(
      queueSongIds.length,
      startIndex + _kQueueCoverArtPrefetchAheadCount + 1,
    );
    if (endExclusive <= startIndex) {
      return;
    }

    final targetSongIds = queueSongIds
        .sublist(startIndex, endExclusive)
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (targetSongIds.isEmpty) {
      return;
    }

    final dao = ref.read(navisDatabaseProvider).libraryDao;
    final songs = await dao.getSongsByIds(targetSongIds);
    if (!mounted || token != _queueCoverArtPrefetchToken || songs.isEmpty) {
      return;
    }

    final cacheManager = ref.read(coverArtCacheManagerProvider);

    for (final song in songs) {
      if (!mounted || token != _queueCoverArtPrefetchToken) {
        return;
      }
      final coverArtId = (song.coverArt ?? '').trim();
      if (coverArtId.isEmpty) {
        continue;
      }
      final cacheKey = coverArtImageCacheKey(
        coverArtId,
        _kQueueCoverArtPrefetchSizePx,
      );
      if (_queueCoverArtPrefetchedKeys.contains(cacheKey)) {
        continue;
      }

      final existing = await cacheManager.getFileFromCache(cacheKey);
      if (existing != null) {
        _rememberPrefetchedQueueCoverArt(cacheKey);
        continue;
      }

      final url = api
          .getCoverArtUrl(id: coverArtId, size: _kQueueCoverArtPrefetchSizePx)
          .toString();
      try {
        await cacheManager.downloadFile(url, key: cacheKey);
        _rememberPrefetchedQueueCoverArt(cacheKey);
      } on Object {
        // Best-effort warmup: ignore network/cache errors.
      }
    }
  }

  void _rememberPrefetchedQueueCoverArt(String cacheKey) {
    if (!_queueCoverArtPrefetchedKeys.add(cacheKey)) {
      return;
    }
    _queueCoverArtPrefetchedOrder.addLast(cacheKey);
    while (_queueCoverArtPrefetchedOrder.length >
        _kQueueCoverArtPrefetchDedupeCap) {
      final oldest = _queueCoverArtPrefetchedOrder.removeFirst();
      _queueCoverArtPrefetchedKeys.remove(oldest);
    }
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

  void _hideQueueWithAnimation() {
    AppLogger.debug('[ACP_INPUT] queue dismiss requested (animated)');
    _restoreQueueFocusOnDismiss = true;
    final overlayState = _queueOverlayKey.currentState;
    if (overlayState != null) {
      overlayState.dismissAnimated();
      return;
    }
    ref.read(playerOverlayStackProvider.notifier).hideQueue();
    _restoreQueueInvokerFocus();
    _restoreQueueFocusOnDismiss = false;
  }

  void _showQueueOverlay({
    required bool queueOnly,
    FocusNode? invokerFocusNode,
  }) {
    AppLogger.debug('[ACP_INPUT] queue show requested (queueOnly=$queueOnly)');
    _queueReturnFocusNode =
        invokerFocusNode ?? FocusManager.instance.primaryFocus;
    final overlay = ref.read(playerOverlayStackProvider.notifier);
    if (queueOnly) {
      overlay.showQueueOnly();
    } else {
      overlay.showQueue();
    }
  }

  void _hideQueueImmediately({bool restoreFocus = false}) {
    AppLogger.debug(
      '[ACP_INPUT] queue dismiss requested (immediate, restoreFocus=$restoreFocus)',
    );
    ref.read(playerOverlayStackProvider.notifier).hideQueue();
    if (restoreFocus) {
      _restoreQueueInvokerFocus();
    }
    _restoreQueueFocusOnDismiss = false;
  }

  void _handleQueueOverlayDismissed() {
    AppLogger.debug('[ACP_INPUT] queue dismissed');
    ref.read(playerOverlayStackProvider.notifier).hideQueue();
    if (_restoreQueueFocusOnDismiss) {
      _restoreQueueInvokerFocus();
    } else {
      _requestShellFocus();
    }
    _restoreQueueFocusOnDismiss = false;
  }

  void _restoreQueueInvokerFocus() {
    final focusNode = _queueReturnFocusNode;
    _queueReturnFocusNode = null;
    if (focusNode == null || !focusNode.canRequestFocus) {
      _requestShellFocus();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !focusNode.canRequestFocus) {
        return;
      }
      focusNode.requestFocus();
    });
  }

  void _requestShellFocus() {
    if (!_shellFocusNode.canRequestFocus) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_shellFocusNode.canRequestFocus) {
        return;
      }
      _shellFocusNode.requestFocus();
    });
  }

  void _openQuickSearchOverlay() {
    final expanded = ref.read(playerSheetExpandedProvider);
    final queueVisible = ref.read(queueOverlayVisibleProvider);
    AppLogger.debug(
      '[ACP_INPUT] quickSearch open requested (alreadyOpen=$_showQuickSearchOverlay, expanded=$expanded, queue=$queueVisible)',
    );
    if (queueVisible) {
      _hideQueueImmediately();
    }
    if (_showQuickSearchOverlay) {
      setState(() {});
      _quickSearchFocusNode.requestFocus();
      return;
    }
    setState(() {
      _showQuickSearchOverlay = true;
    });
    ref.read(quickSearchOverlayVisibleProvider.notifier).visible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_quickSearchFocusNode.canRequestFocus) {
        return;
      }
      _quickSearchFocusNode.requestFocus();
      final text = _quickSearchController.text;
      _quickSearchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: text.length,
      );
    });
  }

  void _closeQuickSearchOverlay() {
    if (!_showQuickSearchOverlay) {
      return;
    }
    AppLogger.debug('[ACP_INPUT] quickSearch close requested');
    setState(() {
      _showQuickSearchOverlay = false;
    });
    ref.read(quickSearchOverlayVisibleProvider.notifier).visible = false;
    _requestShellFocus();
  }

  /// Desktop View presents Now Playing as the lyrics overlay, so the
  /// overlay is the [PlayerOverlayRoute.nowPlaying] entry: navigation,
  /// Escape, back and playback teardown all close it through the stack.
  void _toggleDesktopLyricsOverlay() {
    final overlay = ref.read(playerOverlayStackProvider.notifier);
    final diagnosticsOverride = ref.read(desktopNowPlayingDiagnosticsProvider);
    if (diagnosticsOverride != null) {
      ref.read(desktopNowPlayingDiagnosticsProvider.notifier).clear();
      overlay.collapse();
      return;
    }
    overlay.toggle();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final router = GoRouter.maybeOf(context);
    if (!identical(router, _router)) {
      _router?.routerDelegate.removeListener(_syncLibrarySectionFromLocation);
      _router = router;
      router?.routerDelegate.addListener(_syncLibrarySectionFromLocation);
    }
    if (_didCheckBatteryOptimizationPrompt) {
      return;
    }
    _didCheckBatteryOptimizationPrompt = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybePromptForBatteryOptimization());
    });
  }

  String _playbackErrorMessage(
    AppLocalizations l10n,
    PlaybackActionError error,
  ) {
    final e = error.error;
    if (e is PlaybackUnavailableException) {
      return switch (e.reason) {
        PlaybackUnavailableReason.initializing =>
          l10n.playbackUnavailableInitializing,
        PlaybackUnavailableReason.startupFailed =>
          l10n.playbackUnavailableStartupFailed,
        PlaybackUnavailableReason.unavailable =>
          l10n.playbackUnavailableGeneric,
      };
    }
    if (e is PlaybackSourceUnavailableException) {
      return l10n.playbackUnavailableSource;
    }
    return l10n.playbackActionFailed;
  }

  void _showPlaybackRecoverySheet() {
    if (_playbackRecoverySheetOpen || !mounted) {
      return;
    }
    _playbackRecoverySheetOpen = true;
    unawaited(
      showPlaybackRecoverySheet(context).whenComplete(() {
        if (mounted) {
          _playbackRecoverySheetOpen = false;
        }
      }),
    );
  }

  Future<void> _maybePromptForBatteryOptimization() async {
    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig == null || ref.read(syncIntervalMinutesProvider) <= 0) {
      return;
    }
    // AAOS car displays use a different system model — battery optimization
    // settings don't apply and the sheet can't render correctly at car-screen
    // aspect ratios, so skip entirely.
    if (resolveAdaptiveContext(
      desktopRuntime: ref.read(desktopPresentationRuntimeProvider),
      viewportSize: MediaQuery.sizeOf(context),
      safePadding: MediaQuery.paddingOf(context),
    ).useCompactWideLandscape) {
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
      isScrollControlled: true,
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
    final initialSyncWarning = ref.watch(
      initialSyncCompletionWarningProvider,
    );
    if (initialSyncWarning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !ref.read(initialSyncCompletionWarningProvider)) {
          return;
        }
        _appNoticeController.show(
          message: l10n.initialSyncCompletedWithWarnings,
          level: AppNoticeLevel.info,
        );
        ref.read(initialSyncCompletionWarningProvider.notifier).consume();
      });
    }
    // Keep the sync controller alive without rebuilding the shell on each of
    // its progress updates.
    ref.listen(librarySyncControllerProvider, (_, _) {});
    ref.watch(scrobbleDispatchControllerProvider);
    ref.watch(listenBrainzFeedbackDispatchControllerProvider);
    ref.watch(starSyncDispatchControllerProvider);
    ref.watch(autoDownloadStarredDispatchControllerProvider);
    ref.watch(mixModeReconciliationProvider);

    // Wire the preferred-mix-mode callbacks for Android Auto More-tab actions
    // (Instant Mix / Instant Radio). Registered here because app_shell has
    // access to both the handler and the mix-mode providers, avoiding a
    // circular import in app_providers.dart.
    void _registerPreferredMixCallback(NavisPlaybackHandler? handler) {
      if (handler == null) return;

      // Instant Radio: always activate (never toggle).
      handler.registerPreferredMixCallback(
        (seedSongId) async {
          await activatePreferredMixModeFromContainer(
            ref.container,
            seedSongId: seedSongId,
          );
          if (ref.container.read(recommendationSessionProvider).insertedCount ==
              0) {
            throw StateError('Instant Mix did not insert playable tracks.');
          }
        },
      );

      // Instant Mix: toggle like the in-app player button.
      handler.registerPreferredMixToggleCallback(
        (seedSongId) => togglePreferredMixModeFromContainer(
          ref.container,
          seedSongId: seedSongId,
        ),
      );
    }

    _registerPreferredMixCallback(ref.read(audioHandlerProvider));
    ref.listen<NavisPlaybackHandler?>(
      audioHandlerProvider,
      (prev, next) => _registerPreferredMixCallback(next),
    );

    // Global Instant Mix snackbar / error notifications (shown on any screen).
    ref.listen<InstantMixState>(instantMixProvider, (prev, next) {
      if (!mounted) return;
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        _appNoticeController.show(
          message: l10n.nowPlayingInstantMixStarted(count),
          level: AppNoticeLevel.success,
        );
        ref.read(instantMixProvider.notifier).clearSnackbar();
      }
      if (next.error != null && next.error != prev?.error) {
        final msg = next.error == InstantMixError.unsupported
            ? l10n.nowPlayingInstantMixUnsupported
            : l10n.nowPlayingInstantMixError;
        _appNoticeController.show(message: msg, level: AppNoticeLevel.error);
        ref.read(instantMixProvider.notifier).clearError();
      }
    });

    ref.listen<PersonalRadioState>(personalRadioProvider, (previous, next) {
      if (!mounted || !next.active || !(previous?.active ?? false)) return;
      if (next.source != previous?.source && next.source != null) {
        _appNoticeController.show(
          message: l10n.instantRadioFallback,
          level: AppNoticeLevel.info,
        );
      }
    });

    // Global Smart Queue snackbar / error notifications.
    ref.listen<SmartQueueState>(smartQueueProvider, (prev, next) {
      if (!mounted) return;
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        _appNoticeController.show(
          message: l10n.smartQueueStarted(count),
          level: AppNoticeLevel.success,
        );
        ref.read(smartQueueProvider.notifier).clearSnackbar();
      }
      if (next.error != null && next.error != prev?.error) {
        final msg = next.error == SmartQueueError.unsupported
            ? l10n.smartQueueUnsupported
            : l10n.smartQueueError;
        _appNoticeController.show(message: msg, level: AppNoticeLevel.error);
        ref.read(smartQueueProvider.notifier).clearError();
      }
      // Show a "stopped" notification when the session ends.
      if ((prev?.active ?? false) && !next.active && next.error == null) {
        _appNoticeController.show(message: l10n.smartQueueStopped);
      }
    });
    // Global Same Vibes snackbar / error notifications.
    ref.listen<SameVibesState>(sameVibesProvider, (prev, next) {
      if (!mounted) return;
      if (ref.read(preferredMixModeProvider) != PreferredMixMode.sameVibes) {
        return;
      }
      if (!(prev?.active ?? false) && next.active && next.refilling) {
        _appNoticeController.show(
          message: '${l10n.nowPlayingSameVibesLabel}...',
        );
      }
      if (next.pendingSnackbar != null &&
          next.pendingSnackbar != prev?.pendingSnackbar) {
        final count = int.tryParse(next.pendingSnackbar ?? '') ?? 0;
        _appNoticeController.show(
          message: l10n.nowPlayingSameVibesStarted(count),
          level: AppNoticeLevel.success,
        );
        ref.read(sameVibesProvider.notifier).clearSnackbar();
      }
      if (next.error != null && next.error != prev?.error) {
        final msg = switch (next.error!) {
          SameVibesError.unsupported => l10n.nowPlayingSameVibesUnsupported,
          SameVibesError.invalidKey => l10n.sameVibesInvalidKey,
          SameVibesError.rateLimited => l10n.sameVibesRateLimited,
          SameVibesError.networkError => l10n.nowPlayingSameVibesError,
        };
        _appNoticeController.show(message: msg, level: AppNoticeLevel.error);
        ref.read(sameVibesProvider.notifier).clearError();
      }
      if ((prev?.active ?? false) && !next.active && next.error == null) {
        _appNoticeController.show(message: l10n.nowPlayingSameVibesStopped);
      }
    });
    // Global Radio stream error snackbar.
    ref.listen<AsyncValue<void>>(radioStreamErrorProvider, (prev, next) {
      if (!mounted) return;
      if (next.hasValue && prev != null && prev.hasValue) {
        _appNoticeController.show(
          message: l10n.radioStreamUnavailable,
          level: AppNoticeLevel.error,
        );
      }
    });
    // Global playback-action error snackbar (fire-and-forget queue actions).
    ref.listen<AsyncValue<PlaybackActionError>>(playbackActionErrorProvider, (
      prev,
      next,
    ) {
      if (!mounted) return;
      final error = next.asData?.value;
      if (error == null) return;
      final unavailable = error.error;
      if (unavailable is PlaybackUnavailableException &&
          (unavailable.reason == PlaybackUnavailableReason.initializing ||
              unavailable.reason == PlaybackUnavailableReason.startupFailed)) {
        _showPlaybackRecoverySheet();
        return;
      }
      _appNoticeController.show(
        message: _playbackErrorMessage(l10n, error),
        level: AppNoticeLevel.error,
      );
    });
    ref.listen<bool>(
      playerStateProvider.select((snapshot) => snapshot.hasActivePlayback),
      (previous, next) {
        if (!next) {
          _queueCoverArtPrefetchDebounce?.cancel();
          _playerSheetProgress.value = 0;
          ref.read(playerOverlayStackProvider.notifier).clear();
          _nowPlayingBackInterceptor = null;
          _compactWideInternalOverlayActive = false;
          _compactWideQueueRequestHandler = null;
          NavService.clearExitPrompt();
        }
      },
    );
    ref.listen<(List<String>, int?, bool)>(
      playerStateProvider.select(
        (snapshot) => (
          snapshot.queueSongIds,
          snapshot.currentIndex,
          snapshot.isRadioMode,
        ),
      ),
      (previous, next) {
        if (!mounted) return;
        final queueSongIds = next.$1;
        final isRadioMode = next.$3;
        if (isRadioMode || queueSongIds.isEmpty) {
          _queueCoverArtPrefetchDebounce?.cancel();
          return;
        }
        _scheduleQueueCoverArtPrefetch();
      },
    );
    final isAuthenticated =
        ref.watch(serverConfigStateProvider).asData?.value != null;
    final reachability = ref.watch(serverReachabilityControllerProvider);
    final showOfflineBanner =
        isAuthenticated &&
        reachability.status == ServerReachabilityStatus.offline;
    final offlineBannerText = reachability.showRetryBanner
        ? l10n.serverOfflineBanner
        : l10n.serverOfflineQuietBanner;
    final appNoticeTopOffset = showOfflineBanner ? 66.0 : 12.0;
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
    final artistId = playback.isRadioMode
        ? null
        : currentSongAsync.asData?.value?.artistId;
    final albumId = playback.isRadioMode
        ? null
        : currentSongAsync.asData?.value?.albumId;
    final coverArtId = playback.isRadioMode
        ? null
        : currentSongAsync.asData?.value?.coverArt;
    final coverArtUrl = playback.isRadioMode
        ? null
        : currentMediaItem?.artUri?.toString();
    final isExternalSource = playback.isRadioMode
        ? false
        : currentSongAsync.asData?.value?.isExternal ?? false;
    final nowPlayingArtUrl = playback.isRadioMode
        ? playback.radioStation?.nowPlayingArtUrl
        : coverArtUrl;
    final showPlayer = playback.hasActivePlayback;
    final isExpanded = ref.watch(playerSheetExpandedProvider);
    final showQueueOverlay = ref.watch(queueOverlayVisibleProvider);
    final visibleLibrarySections = ref.watch(visibleLibrarySectionsProvider);
    final selectedLibrarySection = ref.watch(librarySectionProvider);
    final hasPlayerOverlay = ref.watch(
      playerOverlayStackProvider.select((stack) => stack.isNotEmpty),
    );
    final navigationShell = widget.navigationShell;
    // Every branch is a visible destination, in branch order.
    final visibleBranchIndices = <int>[
      for (final branch in ShellBranch.values) branch.index,
    ];
    final selectedVisibleIndex = visibleBranchIndices.indexOf(
      navigationShell.currentIndex,
    );
    final selectedIndex = selectedVisibleIndex >= 0 ? selectedVisibleIndex : 0;
    final mediaSize = MediaQuery.sizeOf(context);
    final desktopRuntime = ref.watch(desktopPresentationRuntimeProvider);
    final desktopNowPlayingDiagnosticsOverride = ref.watch(
      desktopNowPlayingDiagnosticsProvider,
    );
    final bool showDesktopLyricsOverlay =
        desktopNowPlayingDiagnosticsOverride ?? isExpanded;
    final mediaPadding = MediaQuery.paddingOf(context);
    final mediaViewPadding = MediaQuery.viewPaddingOf(context);
    // On AAOS, the car controls bar is reported via viewPadding.bottom.
    // On Android Auto (phone projection), the car controls bar is NOT reported
    // as any window inset, but the status bar IS reported via viewPadding.top.
    // Both bars are typically the same height on car displays, so use top as a
    // proxy when bottom is unavailable.
    final effectiveCarBottomInset = mediaViewPadding.bottom > 0
        ? mediaViewPadding.bottom
        : mediaViewPadding.top;
    final adaptiveContext = resolveAdaptiveContext(
      desktopRuntime: desktopRuntime,
      viewportSize: mediaSize,
      safePadding: mediaPadding,
    );
    final adaptiveInputPolicy = resolveAdaptiveInputPolicy(
      adaptiveContext: adaptiveContext,
    );
    // Watch shortcut bindings so that the global key handler (which reads them
    // via ref.read) always operates on the latest values after a rebuild.
    ref.watch(desktopShortcutBindingsProvider);
    final screenWidth = mediaSize.width;
    final screenHeight = mediaSize.height;
    final safeHorizontalWidth =
        (screenWidth - mediaPadding.left - mediaPadding.right).clamp(
          0.0,
          double.infinity,
        );
    final isPhoneFormFactor = adaptiveContext.isPhoneFormFactor;
    final useDesktopShell = adaptiveContext.useDesktopShell;
    final desktopLayoutClass = adaptiveContext.desktopLayoutClass;
    final useCompactWideLandscape = adaptiveContext.useCompactWideLandscape;
    final useStandardRailNavigation = adaptiveContext.useStandardRailNavigation;
    final useRailNavigation = adaptiveContext.useRailNavigation;
    final isMiniPlayerMode = desktopRuntime
        ? ref.watch(
            desktopWindowControllerProvider.select((c) => c.isMiniPlayerMode),
          )
        : false;
    if (useDesktopShell && !isMiniPlayerMode) {
      _lastDesktopViewSize = mediaSize;
    }
    final desktopTokens = NavisTokens.of(context);
    final configuredNavbarStyle = desktopRuntime
        ? ref.watch(desktopNavbarStyleProvider)
        : 'comfortable';
    final navbarStyle = desktopLayoutClass == DesktopLayoutClass.compactDesktop
        ? 'icons'
        : configuredNavbarStyle;
    final navbarAutohide = desktopRuntime
        ? ref.watch(desktopNavbarAutohideProvider)
        : false;
    final desktopSidebarWidth = switch (navbarStyle) {
      'compact' => 220.0,
      'icons' => 64.0,
      _ =>
        (screenWidth * 0.22)
            .clamp(math.max(260.0, desktopTokens.sidebarWidth * 0.9), 360.0)
            .toDouble(),
    };
    if (desktopRuntime && _lastReportedDesktopViewport != mediaSize) {
      _lastReportedDesktopViewport = mediaSize;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(desktopWindowControllerProvider).updateViewportSize(mediaSize);
      });
    }
    final desktopWindowTransition = desktopRuntime
        ? ref.watch(
            desktopWindowControllerProvider.select(
              (controller) => controller.transitionRequest,
            ),
          )
        : null;
    final miniPlayerBelowMinimum =
        desktopRuntime && isMiniPlayerMode && !supportsMiniPlayer(mediaSize);
    final desktopWindowModeInvalid =
        desktopRuntime &&
        (isMiniPlayerMode
            ? supportsDesktopView(mediaSize)
            : !supportsDesktopView(mediaSize));
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
        (useDesktopShell || useStandardRailNavigation) &&
        screenWidth >= 840 &&
        !isPhoneFormFactor;
    final allowScrollableRail = !isPhoneFormFactor && !useCompactWideLandscape;
    final useWideMiniPlayerStyle = screenWidth >= 960;
    // On AAOS (compactWideLandscape) increase to ~15% of height for a
    // car-friendly strip that is easy to read and tap while driving.
    // The strip renders inside a SizedBox of this height so all internal
    // components must fit comfortably within it.
    final compactBottomMiniPlayerHeight = useCompactWideLandscape
        ? (screenHeight * 0.15).clamp(90.0, 112.0)
        : (screenHeight * 0.18).clamp(80.0, 140.0);
    if (!adaptiveInputPolicy.enableDesktopCommandShortcuts &&
        _showQuickSearchOverlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        AppLogger.debug(
          '[ACP_INPUT] quickSearch force-closed because desktop shortcuts disabled',
        );
        _closeQuickSearchOverlay();
      });
    }
    final brightness = Theme.of(context).brightness;
    final nowPlayingVisualPrewarmKey = showPlayer
        ? nowPlayingVisualCacheKeyFor(
            brightness: brightness,
            coverArtId: coverArtId,
            artUrl: nowPlayingArtUrl,
          )
        : null;

    if (nowPlayingVisualPrewarmKey != _lastNowPlayingVisualPrewarmKey) {
      _lastNowPlayingVisualPrewarmKey = nowPlayingVisualPrewarmKey;
      if (nowPlayingVisualPrewarmKey != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          unawaited(
            prewarmNowPlayingVisuals(
              context: context,
              ref: ref,
              brightness: brightness,
              coverArtId: coverArtId,
              artUrl: nowPlayingArtUrl,
            ),
          );
        });
      }
    }

    if (showPlayer &&
        currentSongId != null &&
        currentSongId != _lastNowPlayingLyricsPrewarmSongId) {
      final lyricsSongId = currentSongId;
      _lastNowPlayingLyricsPrewarmSongId = lyricsSongId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(() async {
          try {
            await ref.read(lyricsProvider(lyricsSongId).future);
          } on Object {
            // Best-effort preload: keep navigation smooth, ignore fetch errors.
          }
        }());
      });
    }

    if (useCompactWideLandscape && showQueueOverlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _hideQueueImmediately();
      });
    }
    final railDestinations = <_ShellDestination>[
      _ShellDestination(icon: Icons.home_outlined, label: l10n.navHome),
      _ShellDestination(
        icon: Icons.library_music_outlined,
        label: l10n.navLibrary,
      ),
      _ShellDestination(icon: Icons.search, label: l10n.navSearch),
      _ShellDestination(icon: Icons.settings_outlined, label: l10n.navSettings),
    ];

    void onDestinationSelected(int index) {
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      if (showQueueOverlay) {
        _hideQueueImmediately();
      }
      if (isExpanded) {
        overlay.collapse();
      }
      _navExpandRequestNotifier.value++;
      final branchIndex = visibleBranchIndices[index];
      if (branchIndex == ShellBranch.search.index) {
        ref.read(searchFocusRequestProvider.notifier).increment();
      }
      if (branchIndex == ShellBranch.home.index &&
          branchIndex == navigationShell.currentIndex) {
        ref.read(homeScrollToTopRequestProvider.notifier).request();
      }
      if (branchIndex == ShellBranch.library.index &&
          branchIndex == navigationShell.currentIndex) {
        ref.read(libraryScrollToTopRequestProvider.notifier).request();
        // Re-selecting Library returns to the section it was showing rather
        // than the bare branch root.
        NavService.openLibrarySection(context, ref, selectedLibrarySection);
        return;
      }
      NavService.switchTab(
        context,
        ref,
        navigationShell,
        ShellBranch.fromIndex(branchIndex),
        initialLocation: branchIndex == navigationShell.currentIndex,
      );
    }

    void onLibrarySectionSelected(LibrarySection section) {
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      if (showQueueOverlay) {
        _hideQueueImmediately();
      }
      if (isExpanded) {
        overlay.collapse();
      }
      final wasSameSection =
          navigationShell.currentIndex == ShellBranch.library.index &&
          selectedLibrarySection == section;
      NavService.openLibrarySection(context, ref, section);
      if (wasSameSection) {
        ref.read(libraryScrollToTopRequestProvider.notifier).request();
      }
    }

    void submitQuickSearch(
      String rawQuery, {
      SearchResultType? filter,
      required bool explicitFilter,
    }) {
      final query = rawQuery.trim();
      AppLogger.debug(
        '[ACP_INPUT] quickSearch submitted query="$query" '
        'filter=${filter?.name} explicitFilter=$explicitFilter',
      );
      // New shortcut searches start compact unless the overlay filter was
      // explicitly changed for this submit.
      if (!explicitFilter) {
        ref.read(searchFilterProvider.notifier).select(null);
      } else {
        ref.read(searchFilterProvider.notifier).select(filter);
      }
      if (query.isNotEmpty) {
        ref.read(searchQueryProvider.notifier).submit(query);
        unawaited(
          ref.read(navisDatabaseProvider).historyDao.saveSearchQuery(query),
        );
      }
      _closeQuickSearchOverlay();
      onDestinationSelected(ShellBranch.search.index);
    }

    Future<void> executeDesktopCommand(DesktopCommandAction action) async {
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      final hasPlayback = ref.read(playerStateProvider).hasActivePlayback;
      final expanded = ref.read(playerSheetExpandedProvider);
      final queueVisible = ref.read(queueOverlayVisibleProvider);
      AppLogger.debug(
        '[ACP_INPUT] desktopCommand action=${action.name} quickSearch=$_showQuickSearchOverlay queue=$queueVisible expanded=$expanded hasPlayback=$hasPlayback',
      );
      // Mini Player shows no pages or shell panels, so commands that would
      // change them are ignored rather than acting invisibly.
      if (desktopRuntime &&
          ref.read(desktopWindowControllerProvider).isMiniPlayerMode &&
          _pageCommands.contains(action)) {
        return;
      }
      switch (action) {
        case DesktopCommandAction.focusSearch:
          onDestinationSelected(ShellBranch.search.index);
          return;
        case DesktopCommandAction.openQuickSearch:
          _openQuickSearchOverlay();
          return;
        case DesktopCommandAction.toggleQueue:
          if (!hasPlayback) {
            return;
          }
          if (queueVisible) {
            _hideQueueWithAnimation();
          } else if (hasPlayback) {
            _showQueueOverlay(queueOnly: useDesktopShell);
          }
          return;
        case DesktopCommandAction.toggleNowPlaying:
          // Escape: close the top-most surface without leaving the page.
          if (_dismissTopShellSurface()) {
            return;
          }
          if (expanded) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape collapsed now-playing',
            );
            overlay.collapse();
            return;
          }
          // Dismiss any Navigator-pushed modal (dialog, bottom sheet, etc.)
          // before falling through to no-op.
          final rootNav = Navigator.maybeOf(context, rootNavigator: true);
          if (rootNav != null && rootNav.canPop()) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape popped navigator modal',
            );
            rootNav.pop();
          } else {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape no-op (nothing to dismiss)',
            );
          }
          return;
        case DesktopCommandAction.goHome:
          onDestinationSelected(ShellBranch.home.index);
          return;
        case DesktopCommandAction.goLibrary:
          // Cycling sections only makes sense on the Library root; from a
          // Library detail page, or another tab, the shortcut opens Library.
          final onLibraryRoot =
              navigationShell.currentIndex == ShellBranch.library.index &&
              GoRouter.of(context).state.uri.path == AppRoutes.library;
          if (!onLibraryRoot) {
            onDestinationSelected(ShellBranch.library.index);
          } else {
            // Already on library — cycle to the next available section.
            final availableSections = visibleLibrarySections;
            if (availableSections.isEmpty) {
              return;
            }
            final currentIdx = availableSections.indexOf(
              selectedLibrarySection,
            );
            final nextIdx = (currentIdx + 1) % availableSections.length;
            onLibrarySectionSelected(availableSections[nextIdx]);
          }
          return;
        case DesktopCommandAction.goSearch:
          onDestinationSelected(ShellBranch.search.index);
          return;
        case DesktopCommandAction.goSettings:
          onDestinationSelected(ShellBranch.settings.index);
          return;
        case DesktopCommandAction.navigateBack:
          await NavService.navigateHistory(ref, forward: false);
          return;
        case DesktopCommandAction.navigateForward:
          await NavService.navigateHistory(ref, forward: true);
          return;
        case DesktopCommandAction.playPause:
          final handler = ref.read(audioHandlerProvider);
          final playbackSnapshot = ref.read(playerStateProvider);
          if (handler == null) {
            return;
          }
          if (playbackSnapshot.playing) {
            await handler.pause();
          } else {
            await handler.play();
          }
          return;
        case DesktopCommandAction.nextTrack:
          final handler = ref.read(audioHandlerProvider);
          final playbackSnapshot = ref.read(playerStateProvider);
          if (handler == null) {
            return;
          }
          if (playbackSnapshot.isRadioMode) {
            await handler.stopRadio();
          } else {
            await handler.skipToNext();
          }
          return;
        case DesktopCommandAction.previousTrack:
          if (ref.read(playerStateProvider).isRadioMode) {
            return;
          }
          await ref.read(audioHandlerProvider)?.skipToPrevious();
          return;
        case DesktopCommandAction.refreshLibrary:
          unawaited(
            ref.read(librarySyncControllerProvider.notifier).syncNow(),
          );
          return;
        case DesktopCommandAction.forceRescanLibrary:
          unawaited(
            ref.read(librarySyncControllerProvider.notifier).forceFullSync(),
          );
          return;
        case DesktopCommandAction.speedUp:
        case DesktopCommandAction.speedDown:
        case DesktopCommandAction.speedReset:
          final result = await nudgePlaybackSpeed(
            ref,
            hundredths: switch (action) {
              DesktopCommandAction.speedUp => 10,
              DesktopCommandAction.speedDown => -10,
              _ => null,
            },
          );
          if (result == null || !mounted) return;
          final l10n = AppLocalizations.of(context)!;
          final speed =
              ref
                  .read(playbackAdjustmentsProvider)
                  .asData
                  ?.value
                  .values
                  .speed ??
              1;
          _appNoticeController.show(
            duration: const Duration(milliseconds: 1200),
            message: switch (result) {
              PlaybackSpeedNudgeResult.changed =>
                l10n.playbackSpeedChangedNotice(
                  l10n.playbackSpeedMultiplierValue(
                    formatAdjustmentNumber(speed, signed: false),
                  ),
                ),
              PlaybackSpeedNudgeResult.minimumReached =>
                l10n.playbackSpeedMinimumReached,
              PlaybackSpeedNudgeResult.maximumReached =>
                l10n.playbackSpeedMaximumReached,
            },
          );
          return;
      }
    }

    // Cache policy and executor so the global keyboard handler can read them
    // outside of build() (InheritedWidget lookups from a descendant scope are
    // not visible via this widget's own context).
    _cachedInputPolicy = adaptiveInputPolicy;
    _executeDesktopCommand = executeDesktopCommand;

    // The sidebar shows Library sections only in these layouts; auto-hide
    // counts as hidden so the Library page does not reflow on hover.
    final sidebarAllowsLibrarySections =
        showLibrarySubNavigation &&
        (useDesktopShell
            ? navbarStyle != 'icons' && !navbarAutohide
            : !useCompactWideLandscape);
    final shell = LibrarySectionNavigationScope(
      sidebarAllowsSections: sidebarAllowsLibrarySections,
      sectionsFit: _librarySectionsFitSidebar,
      child: AdaptiveContextScope(
        adaptiveContext: adaptiveContext,
        child: AdaptiveInputPolicyScope(
          policy: adaptiveInputPolicy,
          child: BackButtonListener(
            onBackButtonPressed: () async {
              // Let modal routes above the shell (dialogs, sheets) handle back
              // themselves — only intercept when the shell route is topmost.
              if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
                return false;
              }
              _handleShellBack();
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
                if (didPop || !(ModalRoute.of(context)?.isCurrent ?? true))
                  return;
                _handleShellBack();
              },
              child: AppNoticeScope(
                notifier: _appNoticeController,
                child: Scaffold(
                  key: const ValueKey<String>('appShellScaffold'),
                  // Keep the expanded player at full height even if a hidden text field
                  // elsewhere (e.g. Search) still has keyboard insets in flight.
                  resizeToAvoidBottomInset:
                      !useCompactWideLandscape && !(showPlayer && isExpanded),
                  body: Stack(
                    children: <Widget>[
                      if (useDesktopShell &&
                          (!isMiniPlayerMode || _lastDesktopViewSize != null))
                        // Kept mounted, hidden, in Mini Player once Desktop
                        // View has been shown, so every tab keeps its pages;
                        // it must stay the first child.
                        _HiddenWorkspaceLayer(
                          key: const ValueKey<String>('desktopWorkspaceLayer'),
                          hidden: desktopRuntime && isMiniPlayerMode,
                          desktopViewSize: _lastDesktopViewSize ?? mediaSize,
                          child: _DesktopWorkspace(
                            desktopLayoutClass: desktopLayoutClass,
                            sidebarWidth: desktopSidebarWidth,
                            navbarStyle: navbarStyle,
                            navbarAutohide: navbarAutohide,
                            expandRequestNotifier: _navExpandRequestNotifier,
                            selectedIndex: selectedIndex,
                            destinations: railDestinations,
                            showOfflineBanner: showOfflineBanner,
                            offlineBannerText: offlineBannerText,
                            showPlayer: showPlayer,
                            showQueueOverlay: showQueueOverlay,
                            hasPlayerOverlay: hasPlayerOverlay,
                            navigationShell: navigationShell,
                            playback: playback,
                            songTitle: songTitle,
                            songArtist: songArtist,
                            artistId: artistId,
                            albumId: albumId,
                            coverArtId: coverArtId,
                            coverArtUrl: coverArtUrl,
                            isExternalSource: isExternalSource,
                            onDestinationSelected: onDestinationSelected,
                            showLibrarySubNavigation: showLibrarySubNavigation,
                            librarySectionsFit: _librarySectionsFitSidebar,
                            selectedLibrarySection: selectedLibrarySection,
                            visibleLibrarySections: visibleLibrarySections,
                            onLibrarySectionSelected: onLibrarySectionSelected,
                            allowScrollableRail: allowScrollableRail,
                            onOpenPlayer: _toggleDesktopLyricsOverlay,
                            onToggleQueue: () {
                              if (showQueueOverlay) {
                                _hideQueueWithAnimation();
                              } else {
                                _showQueueOverlay(
                                  queueOnly: useDesktopShell,
                                  invokerFocusNode:
                                      _desktopQueueToggleFocusNode,
                                );
                              }
                            },
                            onDismissQueue: _handleQueueOverlayDismissed,
                            queueToggleFocusNode: _desktopQueueToggleFocusNode,
                            queueOverlayKey: _queueOverlayKey,
                            showLyricsOverlay: showDesktopLyricsOverlay,
                            onToggleLyrics: _toggleDesktopLyricsOverlay,
                            onSystemBack: () {
                              _handleShellBack();
                            },
                            onToggleAutohide: () async {
                              final db = ref.read(navisDatabaseProvider);
                              await db.appSettingsDao
                                  .updateDesktopNavbarAutohide(
                                    !navbarAutohide,
                                  );
                            },
                          ),
                        ),
                      if (desktopRuntime && isMiniPlayerMode)
                        if (miniPlayerBelowMinimum)
                          const _DesktopMiniPlayerUndersizedSurface()
                        else
                          _DesktopMiniPlayerSurface(
                            playback: playback,
                            songTitle: songTitle,
                            songArtist: songArtist,
                            coverArtId: coverArtId,
                            coverArtUrl: nowPlayingArtUrl,
                            isExternalSource: isExternalSource,
                            onBackInterceptorChanged: (handler) {
                              _nowPlayingBackInterceptor = handler;
                            },
                            onCompactWideOverlayActiveChanged:
                                _handleCompactWideOverlayActiveChanged,
                            onCompactWideQueueRequestChanged:
                                _handleCompactWideQueueRequestChanged,
                          )
                      else if (useDesktopShell)
                        const SizedBox.shrink()
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
                                  minimum: EdgeInsets.only(
                                    bottom: effectiveCarBottomInset,
                                  ),
                                  child: SizedBox(
                                    width: sideRailWidth,
                                    child: Padding(
                                      padding: useCompactWideLandscape
                                          ? const EdgeInsets.fromLTRB(
                                              0,
                                              8,
                                              0,
                                              8,
                                            )
                                          : const EdgeInsets.fromLTRB(
                                              18,
                                              14,
                                              18,
                                              14,
                                            ),
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
                                              librarySectionsFit:
                                                  _librarySectionsFitSidebar,
                                              selectedLibrarySection:
                                                  selectedLibrarySection,
                                              visibleLibrarySections:
                                                  visibleLibrarySections,
                                              onLibrarySectionSelected:
                                                  onLibrarySectionSelected,
                                              allowScrollableRail:
                                                  allowScrollableRail,
                                              showPlayer: showPlayer,
                                              playback: playback,
                                              songTitle: songTitle,
                                              songArtist: songArtist,
                                              artistId: artistId,
                                              albumId: albumId,
                                              coverArtId: coverArtId,
                                              coverArtUrl: coverArtUrl,
                                              isExternalSource:
                                                  isExternalSource,
                                              isRadio: playback.isRadioMode,
                                              radioArtUrl: playback
                                                  .radioStation
                                                  ?.nowPlayingArtUrl,
                                              onOpenPlayer: () {
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
                                  ),
                                ),
                              ),
                              Expanded(
                                child: SafeArea(
                                  left: false,
                                  top: false,
                                  right: false,
                                  bottom:
                                      !(useCompactWideLandscape && showPlayer),
                                  // viewPadding (not padding) covers AAOS
                                  // car bars that report as gesture-nav
                                  // insets (padding.bottom = 0). On Android
                                  // Auto (phone projection), the bottom bar
                                  // is not reported at all; effectiveCarBottomInset
                                  // falls back to viewPadding.top as a proxy
                                  // since both car bars are typically equal height.
                                  // In compact-wide playback, the mini
                                  // player itself owns the bottom edge, so
                                  // do not reserve a second gap below it.
                                  minimum: EdgeInsets.only(
                                    bottom:
                                        useCompactWideLandscape && showPlayer
                                        ? 0
                                        : effectiveCarBottomInset,
                                  ),
                                  child: Column(
                                    children: <Widget>[
                                      if (showOfflineBanner)
                                        Material(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.surfaceContainerHigh,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 16,
                                              vertical: 12,
                                            ),
                                            child: Row(
                                              children: <Widget>[
                                                Icon(
                                                  Icons.cloud_off_outlined,
                                                  color:
                                                      Theme.of(
                                                            context,
                                                          )
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: Text(
                                                    offlineBannerText,
                                                    style: TextStyle(
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      Expanded(
                                        child: NotificationListener<NavigationNotification>(
                                          // Absorb branch-level NavigationNotification so
                                          // canHandlePop:false from the branch navigator
                                          // never reaches the Router and sets
                                          // setFrameworkHandlesBack(false) on Android 14+.
                                          onNotification: (_) => true,
                                          child: NavigatorPopHandler<Object?>(
                                            enabled: true,
                                            onPopWithResult: (result) {
                                              _handleShellBack();
                                            },
                                            child:
                                                useCompactWideLandscape &&
                                                    showPlayer
                                                ? Stack(
                                                    children: <Widget>[
                                                      // Inset the content area from the
                                                      // bottom so the mini player strip
                                                      // never covers page content.
                                                      AnimatedPositioned(
                                                        duration:
                                                            const Duration(
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
                                                          isExpanded:
                                                              isExpanded,
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
                                                              playback:
                                                                  playback,
                                                              flattenWideStyle:
                                                                  true,
                                                              compactWideLandscapeMode:
                                                                  true,
                                                              enableVerticalExpandGesture:
                                                                  false,
                                                              songTitle:
                                                                  songTitle,
                                                              songArtist:
                                                                  songArtist,
                                                              coverArtId:
                                                                  coverArtId,
                                                              coverArtUrl:
                                                                  coverArtUrl,
                                                              isExternalSource:
                                                                  isExternalSource,
                                                              isRadio: playback
                                                                  .isRadioMode,
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
                                                            wideEmbeddedMode:
                                                                true,
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
                                                            duration:
                                                                const Duration(
                                                                  milliseconds:
                                                                      280,
                                                                ),
                                                            curve:
                                                                Curves.easeOut,
                                                            offset: isExpanded
                                                                ? Offset.zero
                                                                : const Offset(
                                                                    0,
                                                                    1,
                                                                  ),
                                                            child: NowPlayingScreen(
                                                              wideEmbeddedMode:
                                                                  true,
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
                                                                  (
                                                                    handler,
                                                                  ) {
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
                                                            key:
                                                                _queueOverlayKey,
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
                                color: Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHigh,
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
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          offlineBannerText,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            Expanded(
                              child: NotificationListener<NavigationNotification>(
                                // Absorb branch-level NavigationNotification so
                                // canHandlePop:false from the branch navigator
                                // never reaches the Router and sets
                                // setFrameworkHandlesBack(false) on Android 14+.
                                onNotification: (_) => true,
                                child: NavigatorPopHandler<Object?>(
                                  enabled: true,
                                  onPopWithResult: (result) {
                                    _handleShellBack();
                                  },
                                  child: navigationShell,
                                ),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 260),
                              curve: Curves.easeOutCubic,
                              height: showPlayer && !isExpanded
                                  ? ExpandablePlayerSheet.miniPlayerHeight
                                  : 0.0,
                            ),
                          ],
                        ),
                      if (!useDesktopShell && !useRailNavigation)
                        _SlideUpPlayerTransition(
                          showPlayer: showPlayer,
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(20),
                            child: ExpandablePlayerSheet(
                              isExpanded: isExpanded,
                              onProgressChanged: (value) {
                                final clamped = value.clamp(0.0, 1.0);
                                if ((_playerSheetProgress.value - clamped)
                                        .abs() >
                                    0.001) {
                                  _playerSheetProgress.value = clamped;
                                }
                              },
                              onExpand: () {
                                // Dismiss the keyboard (e.g. search bar) before expanding
                                // so the Now Playing screen isn't squished.
                                NavService.dismissKeyboard(context);
                                ref
                                    .read(
                                      playerOverlayStackProvider.notifier,
                                    )
                                    .expand();
                              },
                              onCollapse: () => ref
                                  .read(playerOverlayStackProvider.notifier)
                                  .collapse(),
                              onSwipeUp: () =>
                                  NavService.showQueue(context, ref),
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
                                      isExternalSource: isExternalSource,
                                      isRadio: playback.isRadioMode,
                                      radioArtUrl: playback
                                          .radioStation
                                          ?.nowPlayingArtUrl,
                                      onTap: () {
                                        // Dismiss keyboard before expanding.
                                        NavService.dismissKeyboard(context);
                                        ref
                                            .read(
                                              playerOverlayStackProvider
                                                  .notifier,
                                            )
                                            .expand();
                                      },
                                    ),
                              fullPlayer: ProviderScope(
                                overrides: [
                                  playerStateProvider.overrideWithValue(
                                    playback,
                                  ),
                                ],
                                child: NowPlayingScreen(
                                  onShowQueue: () =>
                                      NavService.showQueue(context, ref),
                                  onCollapse: () => ref
                                      .read(
                                        playerOverlayStackProvider.notifier,
                                      )
                                      .collapse(),
                                  onBackInterceptorChanged: (handler) {
                                    _nowPlayingBackInterceptor = handler;
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (showPlayer &&
                          !useDesktopShell &&
                          showQueueOverlay &&
                          !useRailNavigation)
                        Positioned.fill(
                          left: 0,
                          child: FocusTraversalOrder(
                            order: const NumericFocusOrder(10),
                            child: _QueueOverlay(
                              key: _queueOverlayKey,
                              fullscreen: useRailNavigation,
                              onDismiss: _handleQueueOverlayDismissed,
                            ),
                          ),
                        ),
                      if (_showQuickSearchOverlay &&
                          adaptiveInputPolicy.enableDesktopCommandShortcuts)
                        Positioned.fill(
                          child: _DesktopQuickSearchOverlay(
                            controller: _quickSearchController,
                            focusNode: _quickSearchFocusNode,
                            onDismiss: _closeQuickSearchOverlay,
                            onSubmitted: submitQuickSearch,
                          ),
                        ),
                      if (desktopWindowModeInvalid)
                        Positioned.fill(
                          child: _DesktopWindowTransitionGate(
                            mode: isMiniPlayerMode
                                ? DesktopWindowMode.miniPlayer
                                : DesktopWindowMode.desktop,
                            request: desktopWindowTransition,
                          ),
                        ),
                      AppNoticeHost(
                        controller: _appNoticeController,
                        topOffset: appNoticeTopOffset,
                      ),
                    ],
                  ),
                  bottomNavigationBar: useDesktopShell || useRailNavigation
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
                                    NavigationDestinationLabelBehavior
                                        .onlyShowSelected,
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
            ),
          ),
        ),
      ),
    );

    final activeShell = HomeActivityScope(
      active:
          navigationShell.currentIndex == ShellBranch.home.index &&
          (ModalRoute.of(context)?.isCurrent ?? true),
      child: shell,
    );

    // Install/remove the global hardware-keyboard handler based on policy.
    if (adaptiveInputPolicy.enableDesktopCommandShortcuts ||
        adaptiveInputPolicy.enableEscapeOverlayPriority) {
      _installGlobalKeyHandler();
    } else {
      _removeGlobalKeyHandler();
    }

    if (!adaptiveInputPolicy.enableDeterministicTraversal) {
      return activeShell;
    }

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(
        focusNode: _shellFocusNode,
        autofocus: true,
        child: activeShell,
      ),
    );
  }
}

/// Hosts the desktop workspace, hiding it while Mini Player is shown.
///
/// The workspace stays mounted so the navigation shell keeps every tab's
/// pages and their state. Hidden, it neither paints, animates, takes focus
/// nor counts as active, and it is laid out at the last Desktop View size so
/// the small Mini Player window does not squeeze it. The widget structure is
/// identical in both states so switching never remounts the workspace.
class _HiddenWorkspaceLayer extends StatelessWidget {
  const _HiddenWorkspaceLayer({
    required this.hidden,
    required this.desktopViewSize,
    required this.child,
    super.key,
  });

  final bool hidden;
  final Size desktopViewSize;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final active = !hidden && HomeActivityScope.of(context);
    return Offstage(
      offstage: hidden,
      child: TickerMode(
        enabled: !hidden,
        child: ExcludeFocus(
          excluding: hidden,
          child: HomeActivityScope(
            active: active,
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: hidden ? desktopViewSize.width : null,
              maxWidth: hidden ? desktopViewSize.width : null,
              minHeight: hidden ? desktopViewSize.height : null,
              maxHeight: hidden ? desktopViewSize.height : null,
              child: MediaQuery(
                data: hidden
                    ? mediaQuery.copyWith(size: desktopViewSize)
                    : mediaQuery,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
