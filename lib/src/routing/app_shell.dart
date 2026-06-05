import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/common_widgets/cover_art_viewer.dart';
import 'package:navis/src/common_widgets/expandable_player_sheet.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_playback_sync_bridge.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';
import 'package:navis/src/features/player/presentation/normal_playback_metadata_navigation.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_active_session_indicator.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/presentation/group_listening_session_controller.dart';
import 'package:navis/src/features/library/presentation/star_sync_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/desktop_tokens.dart';
import 'package:navis/src/utils/artist_utils.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/format_utils.dart';
import 'package:navis/src/utils/song_id_utils.dart';

part 'app_shell_support_widgets.dart';
part 'app_shell_quick_search_overlay.dart';
part 'app_shell_desktop_workspace.dart';
part 'app_shell_desktop_player_bar.dart';
part 'app_shell_queue_overlay.dart';
part 'app_shell_navigation_widgets.dart';
part 'app_shell_mini_player.dart';
part 'app_shell_desktop_lyrics_overlay.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const double _sideRailWidth = 270;
  static const int _kQueueCoverArtPrefetchAheadCount = 6;
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
  bool Function()? _nowPlayingBackInterceptor;
  bool _compactWideInternalOverlayActive = false;
  VoidCallback? _compactWideQueueRequestHandler;
  String? _lastNowPlayingVisualPrewarmKey;
  String? _lastNowPlayingLyricsPrewarmSongId;
  FocusNode? _queueReturnFocusNode;
  bool _restoreQueueFocusOnDismiss = false;
  bool _showQuickSearchOverlay = false;
  bool _showDesktopLyricsOverlay = false;
  Timer? _queueCoverArtPrefetchDebounce;
  int _queueCoverArtPrefetchToken = 0;
  bool _globalKeyHandlerInstalled = false;
  Future<void> Function(DesktopCommandAction)? _executeDesktopCommand;
  final ValueNotifier<int> _navExpandRequestNotifier = ValueNotifier<int>(0);
  // Cached so the global HardwareKeyboard handler can read it outside build().
  // `AdaptiveInputPolicyScope` is a *descendant* of this widget, so
  // `context.dependOnInheritedWidgetOfExactType` cannot see it — caching is
  // the only correct approach.
  AdaptiveInputPolicy? _cachedInputPolicy;

  // NOTE: We intentionally do NOT use WidgetsBindingObserver.didPopRoute()
  // for back-button handling. That observer fires BEFORE the Navigator
  // processes the event, which means it would consume back presses that
  // should dismiss higher-priority UI first. Instead we let Navigator-owned
  // routes (dialogs, bottom sheets, etc.) handle back normally and only apply
  // shell back behavior when this shell route is actually current.

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _removeGlobalKeyHandler();
    _queueCoverArtPrefetchDebounce?.cancel();
    _quickSearchController.dispose();
    _quickSearchFocusNode.dispose();
    _shellFocusNode.dispose();
    _desktopQueueToggleFocusNode.dispose();
    _appNoticeController.dispose();
    _playerSheetProgress.dispose();
    _navExpandRequestNotifier.dispose();
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

  void _toggleDesktopLyricsOverlay() {
    setState(() => _showDesktopLyricsOverlay = !_showDesktopLyricsOverlay);
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

  Future<void> _maybePromptForBatteryOptimization() async {
    final serverConfig = ref.read(serverConfigStateProvider).asData?.value;
    if (serverConfig == null || ref.read(syncIntervalMinutesProvider) <= 0) {
      return;
    }
    // AAOS car displays use a different system model — battery optimization
    // settings don't apply and the sheet can't render correctly at car-screen
    // aspect ratios, so skip entirely.
    if (resolveAdaptiveContext(
      desktopRuntime: isDesktopRuntime,
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
    ref.watch(librarySyncControllerProvider);
    ref.watch(groupListeningPlaybackSyncBridgeProvider);
    ref.watch(scrobbleDispatchControllerProvider);
    ref.watch(starSyncDispatchControllerProvider);
    ref.watch(autoDownloadStarredDispatchControllerProvider);

    // Wire the preferred-mix-mode callbacks for Android Auto More-tab actions
    // (Instant Mix / Instant Radio). Registered here because app_shell has
    // access to both the handler and the mix-mode providers, avoiding a
    // circular import in app_providers.dart.
    void _registerPreferredMixCallback(NavisPlaybackHandler? handler) {
      if (handler == null) return;

      // Instant Radio: always activate (never toggle).
      handler.registerPreferredMixCallback(
        (seedSongId) => activatePreferredMixModeFromContainer(
          ref.container,
          seedSongId: seedSongId,
        ),
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
        final msg = next.error == SameVibesError.unsupported
            ? l10n.nowPlayingSameVibesUnsupported
            : l10n.nowPlayingSameVibesError;
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
    ref.listen<GroupListeningSessionState>(
      groupListeningSessionControllerProvider,
      (prev, next) {
        if (!mounted) return;
        final prevHad = prev?.hasActiveRoom ?? false;
        final nextHad = next.hasActiveRoom;
        if (!prevHad && nextHad) {
          final isHost = next.room?.self.role == GroupListeningMemberRole.host;
          _appNoticeController.show(
            message: isHost
                ? 'Hosting a Listen Together session'
                : 'Joined a Listen Together session',
            level: AppNoticeLevel.success,
          );
        } else if (prevHad && !nextHad) {
          _appNoticeController.show(
            message: 'Left the Listen Together session',
          );
        }
      },
    );
    final isAuthenticated =
        ref.watch(serverConfigStateProvider).asData?.value != null;
    final reachability = ref.watch(serverReachabilityControllerProvider);
    final showOfflineBanner =
        isAuthenticated &&
        reachability.status == ServerReachabilityStatus.offline;
    final groupListeningSession = ref.watch(
      groupListeningSessionControllerProvider,
    );
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
    final nowPlayingArtUrl = playback.isRadioMode
        ? playback.radioStation?.nowPlayingArtUrl
        : coverArtUrl;
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
      desktopRuntime: isDesktopRuntime,
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
    final isFocusPlayerMode = isDesktopRuntime
        ? ref.watch(
            desktopWindowControllerProvider.select((c) => c.isFocusPlayerMode),
          )
        : false;
    final desktopTokens = desktopTokensOf(context);
    final navbarStyle = isDesktopRuntime
        ? ref.watch(desktopNavbarStyleProvider)
        : 'comfortable';
    final navbarAutohide = isDesktopRuntime
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
      NavService.dismissKeyboard(context);
      NavService.clearExitPrompt();
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      if (showQueueOverlay) {
        _hideQueueImmediately();
      }
      if (isExpanded) {
        overlay.collapse();
      }
      _navExpandRequestNotifier.value++;
      final branchIndex = visibleBranchIndices[index];
      if (branchIndex == _libraryBranchIndex) {
        ref
            .read(librarySectionProvider.notifier)
            .setSection(LibrarySection.albums);
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
        _hideQueueImmediately();
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

    void submitQuickSearch(String rawQuery, {SearchResultType? filter}) {
      final query = rawQuery.trim();
      AppLogger.debug(
        '[ACP_INPUT] quickSearch submitted query="$query" filter=${filter?.name}',
      );
      // If no filter was used in the overlay, reset to "All" so the search
      // screen starts unfiltered.  If a filter was picked, apply it.
      if (filter == null) {
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
      onDestinationSelected(2);
    }

    Future<void> executeDesktopCommand(DesktopCommandAction action) async {
      final overlay = ref.read(playerOverlayStackProvider.notifier);
      final hasPlayback = ref.read(playerStateProvider).hasActivePlayback;
      final expanded = ref.read(playerSheetExpandedProvider);
      final queueVisible = ref.read(queueOverlayVisibleProvider);
      AppLogger.debug(
        '[ACP_INPUT] desktopCommand action=${action.name} quickSearch=$_showQuickSearchOverlay queue=$queueVisible expanded=$expanded hasPlayback=$hasPlayback',
      );
      switch (action) {
        case DesktopCommandAction.focusSearch:
          onDestinationSelected(2);
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
          if (_showQuickSearchOverlay) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape dismissed quick-search',
            );
            _closeQuickSearchOverlay();
            return;
          }
          final queueOverlayState = _queueOverlayKey.currentState;
          final queueDismissing = queueOverlayState?.isDismissing ?? false;
          if (queueVisible && !queueDismissing) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape dismissed queue overlay',
            );
            _hideQueueWithAnimation();
            return;
          }
          if (expanded && (_nowPlayingBackInterceptor?.call() ?? false)) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape handled by now-playing internal overlay',
            );
            return;
          }
          if (expanded) {
            AppLogger.debug(
              '[ACP_INPUT] desktopCommand escape collapsed now-playing',
            );
            overlay.collapse();
          } else {
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
          }
          return;
        case DesktopCommandAction.goHome:
          onDestinationSelected(0);
          return;
        case DesktopCommandAction.goLibrary:
          if (navigationShell.currentIndex != _libraryBranchIndex) {
            onDestinationSelected(1);
          } else {
            // Already on library — cycle to the next available section.
            final availableSections = <LibrarySection>[
              LibrarySection.albums,
              if (showLikedLibraryPage) LibrarySection.liked,
              if (showArtistsLibraryPage) LibrarySection.artists,
              if (showPlaylistsLibraryPage) LibrarySection.playlists,
              if (showRadioLibraryPage) LibrarySection.radio,
            ];
            final currentIdx = availableSections.indexOf(
              selectedLibrarySection,
            );
            final nextIdx = (currentIdx + 1) % availableSections.length;
            onLibrarySectionSelected(availableSections[nextIdx]);
          }
          return;
        case DesktopCommandAction.goSearch:
          onDestinationSelected(2);
          return;
        case DesktopCommandAction.goSettings:
          onDestinationSelected(3);
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
            ref
                .read(librarySyncControllerProvider.notifier)
                .syncNow(preferIncremental: true),
          );
          return;
        case DesktopCommandAction.forceRescanLibrary:
          unawaited(
            ref
                .read(librarySyncControllerProvider.notifier)
                .syncNow(forceFull: true),
          );
          return;
      }
    }

    // Cache policy and executor so the global keyboard handler can read them
    // outside of build() (InheritedWidget lookups from a descendant scope are
    // not visible via this widget's own context).
    _cachedInputPolicy = adaptiveInputPolicy;
    _executeDesktopCommand = executeDesktopCommand;

    final shell = AdaptiveContextScope(
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
            if (isExpanded && (_nowPlayingBackInterceptor?.call() ?? false)) {
              return true;
            }
            // Primary handler: always delegate to the smart back chain
            // (dismiss overlay → pop sub-route → go home → double-tap exit).
            NavService.handleSystemBack(
              ref: ref,
              context: context,
              navigationShell: navigationShell,
              homeBranchIndex: _homeBranchIndex,
              noticeController: _appNoticeController,
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
              if (didPop || !(ModalRoute.of(context)?.isCurrent ?? true))
                return;
              if (isExpanded && (_nowPlayingBackInterceptor?.call() ?? false)) {
                return;
              }
              NavService.handleSystemBack(
                ref: ref,
                context: context,
                navigationShell: navigationShell,
                homeBranchIndex: _homeBranchIndex,
                noticeController: _appNoticeController,
              );
            },
            child: AppNoticeScope(
              notifier: _appNoticeController,
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
                        navbarStyle: navbarStyle,
                        navbarAutohide: navbarAutohide,
                        expandRequestNotifier: _navExpandRequestNotifier,
                        selectedIndex: selectedIndex,
                        destinations: railDestinations,
                        showOfflineBanner: showOfflineBanner,
                        offlineBannerText: l10n.serverOfflineBanner,
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
                        onDestinationSelected: onDestinationSelected,
                        showLibrarySubNavigation: showLibrarySubNavigation,
                        selectedLibrarySection: selectedLibrarySection,
                        showLikedLibraryPage: showLikedLibraryPage,
                        showArtistsLibraryPage: showArtistsLibraryPage,
                        showPlaylistsLibraryPage: showPlaylistsLibraryPage,
                        showRadioLibraryPage: showRadioLibraryPage,
                        onLibrarySectionSelected: onLibrarySectionSelected,
                        allowScrollableRail: allowScrollableRail,
                        onOpenPlayer: _toggleDesktopLyricsOverlay,
                        onToggleQueue: () {
                          if (showQueueOverlay) {
                            _hideQueueWithAnimation();
                          } else {
                            _showQueueOverlay(
                              queueOnly: useDesktopShell,
                              invokerFocusNode: _desktopQueueToggleFocusNode,
                            );
                          }
                        },
                        onDismissQueue: _handleQueueOverlayDismissed,
                        queueToggleFocusNode: _desktopQueueToggleFocusNode,
                        queueOverlayKey: _queueOverlayKey,
                        showLyricsOverlay: _showDesktopLyricsOverlay,
                        onToggleLyrics: _toggleDesktopLyricsOverlay,
                        onSystemBack: () {
                          if (isExpanded &&
                              (_nowPlayingBackInterceptor?.call() ?? false)) {
                            return;
                          }
                          NavService.handleSystemBack(
                            ref: ref,
                            context: context,
                            navigationShell: navigationShell,
                            homeBranchIndex: _homeBranchIndex,
                            noticeController: _appNoticeController,
                          );
                        },
                        onToggleAutohide: () async {
                          final db = ref.read(navisDatabaseProvider);
                          await db.appSettingsDao.updateDesktopNavbarAutohide(
                            !navbarAutohide,
                          );
                        },
                      )
                    else if (useRailNavigation)
                      // In Focus Player Mode with active playback, fill the
                      // entire window with the NowPlayingScreen and skip the
                      // navigation rail entirely.
                      isFocusPlayerMode && showPlayer
                          ? NowPlayingScreen(
                              wideEmbeddedMode: true,
                              onBackInterceptorChanged: (handler) {
                                _nowPlayingBackInterceptor = handler;
                              },
                            )
                          : Padding(
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
                                                  destinations:
                                                      railDestinations,
                                                  selectedIndex: selectedIndex,
                                                  onDestinationSelected:
                                                      onDestinationSelected,
                                                )
                                              : _RailSidebar(
                                                  selectedIndex: selectedIndex,
                                                  onDestinationSelected:
                                                      onDestinationSelected,
                                                  destinations:
                                                      railDestinations,
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
                                          !(useCompactWideLandscape &&
                                              showPlayer),
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
                                            useCompactWideLandscape &&
                                                showPlayer
                                            ? 0
                                            : effectiveCarBottomInset,
                                      ),
                                      child: Column(
                                        children: <Widget>[
                                          if (showOfflineBanner)
                                            Material(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.errorContainer,
                                              child: Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 16,
                                                      vertical: 12,
                                                    ),
                                                child: Row(
                                                  children: <Widget>[
                                                    Icon(
                                                      Icons.cloud_off_outlined,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .onErrorContainer,
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Text(
                                                        l10n.serverOfflineBanner,
                                                        style: TextStyle(
                                                          color: Theme.of(context)
                                                              .colorScheme
                                                              .onErrorContainer,
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
                                                  if (isExpanded &&
                                                      (_nowPlayingBackInterceptor
                                                              ?.call() ??
                                                          false)) {
                                                    return;
                                                  }
                                                  NavService.handleSystemBack(
                                                    ref: ref,
                                                    context: context,
                                                    navigationShell:
                                                        navigationShell,
                                                    homeBranchIndex:
                                                        _homeBranchIndex,
                                                    noticeController:
                                                        _appNoticeController,
                                                  );
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
                                                                  milliseconds:
                                                                      280,
                                                                ),
                                                            curve:
                                                                Curves.easeOut,
                                                            top: 0,
                                                            left: 0,
                                                            right: 0,
                                                            bottom: isExpanded
                                                                ? 0
                                                                : compactBottomMiniPlayerHeight,
                                                            child:
                                                                navigationShell,
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
                                                            child:
                                                                navigationShell,
                                                          ),
                                                          Positioned.fill(
                                                            child: IgnorePointer(
                                                              ignoring:
                                                                  !isExpanded,
                                                              child: AnimatedSlide(
                                                                duration:
                                                                    const Duration(
                                                                      milliseconds:
                                                                          280,
                                                                    ),
                                                                curve: Curves
                                                                    .easeOut,
                                                                offset:
                                                                    isExpanded
                                                                    ? Offset
                                                                          .zero
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
                                                                fullscreen:
                                                                    true,
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
                            child: NotificationListener<NavigationNotification>(
                              // Absorb branch-level NavigationNotification so
                              // canHandlePop:false from the branch navigator
                              // never reaches the Router and sets
                              // setFrameworkHandlesBack(false) on Android 14+.
                              onNotification: (_) => true,
                              child: NavigatorPopHandler<Object?>(
                                enabled: true,
                                onPopWithResult: (result) {
                                  if (isExpanded &&
                                      (_nowPlayingBackInterceptor?.call() ??
                                          false)) {
                                    return;
                                  }
                                  NavService.handleSystemBack(
                                    ref: ref,
                                    context: context,
                                    navigationShell: navigationShell,
                                    homeBranchIndex: _homeBranchIndex,
                                    noticeController: _appNoticeController,
                                  );
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
                        child: showPlayer
                            ? FocusTraversalOrder(
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
                                          flattenWideStyle:
                                              useWideMiniPlayerStyle,
                                          enableVerticalExpandGesture: false,
                                          songTitle: songTitle,
                                          songArtist: songArtist,
                                          coverArtId: coverArtId,
                                          coverArtUrl: coverArtUrl,
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
                                  fullPlayer: NowPlayingScreen(
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
                              )
                            : const SizedBox.shrink(),
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
                                  icon: Badge(
                                    isLabelVisible:
                                        groupListeningSession.hasActiveRoom,
                                    child: Icon(railDestinations[3].icon),
                                  ),
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
    );

    // Install/remove the global hardware-keyboard handler based on policy.
    if (adaptiveInputPolicy.enableDesktopCommandShortcuts ||
        adaptiveInputPolicy.enableEscapeOverlayPriority) {
      _installGlobalKeyHandler();
    } else {
      _removeGlobalKeyHandler();
    }

    if (!adaptiveInputPolicy.enableDeterministicTraversal) {
      return shell;
    }

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Focus(focusNode: _shellFocusNode, autofocus: true, child: shell),
    );
  }
}
