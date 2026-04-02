import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui';

import 'package:audio_service/audio_service.dart' show AudioServiceRepeatMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/instant_mix_state.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/domain/smart_queue_state.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/player/presentation/smart_queue_notifier.dart';
import 'package:navis/src/features/player/presentation/now_playing_screen.dart';
import 'package:navis/src/features/player/presentation/desktop_volume_slider.dart';
import 'package:navis/src/common_widgets/lyrics_display_widget.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_sheet.dart';
import 'package:navis/src/features/player/presentation/scrobble_dispatch_provider.dart';
import 'package:navis/src/features/player/presentation/smart_queue_sheet.dart';
import 'package:navis/src/features/library/presentation/star_sync_dispatch_provider.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/home/presentation/home_scroll_provider.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart'
    show
        quickSearchOverlayVisibleProvider,
        searchFocusRequestProvider,
        searchFilterProvider,
        searchQueryProvider,
        SearchResultType;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/theme/desktop_tokens.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

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

/// Splits a combined artist string into individual artist names.
///
/// Splits on unambiguous multi-artist delimiters: `;`, `feat.`/`feat`/
/// `featuring`, `ft.`, and ` / ` (space-slash-space).
/// Bare `/` (e.g. K/DA, AC/DC) and suffixes like "Jr." are preserved.
List<String> _splitArtists(String raw) {
  final patterns = [
    RegExp(r'\s*;\s*'),
    RegExp(r'\s+feat(?:uring)?\.?\s+', caseSensitive: false),
    RegExp(r'\s+ft\.\s+', caseSensitive: false),
    RegExp(r'\s+/\s+'), // space-slash-space only — preserves K/DA, AC/DC
  ];
  List<String> parts = [raw.trim()];
  for (final pat in patterns) {
    parts = parts.expand((p) => p.split(pat)).toList();
  }
  return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const double _sideRailWidth = 270;
  static const int _kQueueCoverArtPrefetchAheadCount = 6;
  static const int _kQueueCoverArtPrefetchSizePx = 512;
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

    AppLogger.debug(
      '[ACP_INPUT] global key handler matched ${action.name}',
    );
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

    final cacheManager =
        ref.read(coverArtCacheManagerProvider).asData?.value ??
        defaultCoverArtCacheManager;

    for (final song in songs) {
      if (!mounted || token != _queueCoverArtPrefetchToken) {
        return;
      }
      final coverArtId = (song.coverArt ?? '').trim();
      if (coverArtId.isEmpty) {
        continue;
      }
      final cacheKey = '$coverArtId:$_kQueueCoverArtPrefetchSizePx';
      if (_queueCoverArtPrefetchedKeys.contains(cacheKey)) {
        continue;
      }

      final existing = await cacheManager.getFileFromCache(cacheKey);
      if (existing != null) {
        _rememberPrefetchedQueueCoverArt(cacheKey);
        continue;
      }

      final url = api
          .getCoverArtUrl(
            id: coverArtId,
            size: _kQueueCoverArtPrefetchSizePx,
          )
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
        _appNoticeController.show(
          message: msg,
          level: AppNoticeLevel.error,
        );
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
        _appNoticeController.show(
          message: msg,
          level: AppNoticeLevel.error,
        );
        ref.read(smartQueueProvider.notifier).clearError();
      }
      // Show a "stopped" notification when the session ends.
      if ((prev?.active ?? false) && !next.active && next.error == null) {
        _appNoticeController.show(
          message: l10n.smartQueueStopped,
        );
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
        _appNoticeController.show(
          message: msg,
          level: AppNoticeLevel.error,
        );
        ref.read(sameVibesProvider.notifier).clearError();
      }
      if ((prev?.active ?? false) && !next.active && next.error == null) {
        _appNoticeController.show(
          message: l10n.nowPlayingSameVibesStopped,
        );
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
    final isAuthenticated =
        ref.watch(serverConfigStateProvider).asData?.value != null;
    final reachability = ref.watch(serverReachabilityControllerProvider);
    final showOfflineBanner =
        isAuthenticated &&
        reachability.status == ServerReachabilityStatus.offline;
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
            desktopWindowControllerProvider.select(
              (c) => c.isFocusPlayerMode,
            ),
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
            .clamp(
              math.max(260.0, desktopTokens.sidebarWidth * 0.9),
              360.0,
            )
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
    final compactBottomMiniPlayerHeight = (screenHeight * 0.18).clamp(
      80.0,
      140.0,
    );
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
            // Intercept Android back-button presses before nested branch
            // navigators pop their detail routes. This is what gives the shell's
            // overlay stack priority over pages like album detail.
            if (!hasPlayerOverlay ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
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
                                                      color:
                                                          Theme.of(
                                                                context,
                                                              )
                                                              .colorScheme
                                                              .onErrorContainer,
                                                    ),
                                                    const SizedBox(width: 10),
                                                    Expanded(
                                                      child: Text(
                                                        l10n.serverOfflineBanner,
                                                        style: TextStyle(
                                                          color:
                                                              Theme.of(
                                                                    context,
                                                                  )
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
                                            child: NavigatorPopHandler<Object?>(
                                              enabled: true,
                                              onPopWithResult: (result) {
                                                if (hasPlayerOverlay) {
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
                                                  return;
                                                }
                                                final router = GoRouter.of(
                                                  context,
                                                );
                                                if (!router.canPop()) {
                                                  return;
                                                }
                                                NavService.clearExitPrompt();
                                                router.pop(result);
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
                                                          curve: Curves.easeOut,
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
                            child: NavigatorPopHandler<Object?>(
                              // Always enabled so the branch navigator keeps its
                              // PopEntry registered, preventing Android from
                              // handling back at the system level when a player
                              // overlay is visible.
                              enabled: true,
                              onPopWithResult: (result) {
                                if (hasPlayerOverlay) {
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
                                  return;
                                }
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
      child: Focus(
        focusNode: _shellFocusNode,
        autofocus: true,
        child: shell,
      ),
    );
  }
}

class _DesktopQuickSearchOverlay extends StatefulWidget {
  const _DesktopQuickSearchOverlay({
    required this.controller,
    required this.focusNode,
    required this.onDismiss,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onDismiss;
  final void Function(String, {SearchResultType? filter}) onSubmitted;

  @override
  State<_DesktopQuickSearchOverlay> createState() =>
      _DesktopQuickSearchOverlayState();
}

class _DesktopQuickSearchOverlayState
    extends State<_DesktopQuickSearchOverlay> {
  static const List<String> _filterLabels = [
    'Search Everything',
    'Artists',
    'Albums',
    'Songs',
  ];

  static const List<SearchResultType?> _filterValues = [
    null,
    SearchResultType.artists,
    SearchResultType.albums,
    SearchResultType.songs,
  ];

  int _selectedIndex = 0;

  void _cycleNext() {
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % _filterValues.length;
    });
  }

  void _cyclePrev() {
    setState(() {
      _selectedIndex =
          (_selectedIndex - 1 + _filterValues.length) % _filterValues.length;
    });
  }

  void _submit() {
    widget.onSubmitted(
      widget.controller.text,
      filter: _filterValues[_selectedIndex],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return FocusScope(
      autofocus: true,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (intent) {
                widget.onDismiss();
                return null;
              },
            ),
          },
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return ColoredBox(
                color: Colors.black.withValues(alpha: 0.44 * value),
                child: child,
              );
            },
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: GestureDetector(
                      onTap: () {},
                      child: Material(
                        elevation: 12,
                        color: colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(18),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  const Icon(Icons.search),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Focus(
                                      onKeyEvent: (node, event) {
                                        if (event is KeyDownEvent) {
                                          final key = event.logicalKey;
                                          if (key == LogicalKeyboardKey.tab) {
                                            if (HardwareKeyboard
                                                .instance
                                                .isShiftPressed) {
                                              _cyclePrev();
                                            } else {
                                              _cycleNext();
                                            }
                                            return KeyEventResult.handled;
                                          } else if (key ==
                                              LogicalKeyboardKey.arrowRight) {
                                            _cycleNext();
                                            return KeyEventResult.handled;
                                          } else if (key ==
                                              LogicalKeyboardKey.arrowLeft) {
                                            _cyclePrev();
                                            return KeyEventResult.handled;
                                          }
                                        }
                                        return KeyEventResult.ignored;
                                      },
                                      child: TextField(
                                        key: const ValueKey(
                                          'desktopQuickSearchField',
                                        ),
                                        controller: widget.controller,
                                        focusNode: widget.focusNode,
                                        autofocus: true,
                                        textInputAction: TextInputAction.search,
                                        decoration: const InputDecoration(
                                          hintText: 'Search library...',
                                          border: InputBorder.none,
                                          isDense: true,
                                        ),
                                        onSubmitted: (_) => _submit(),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Search',
                                    onPressed: _submit,
                                    icon: const Icon(
                                      Icons.arrow_forward_rounded,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: <Widget>[
                                  for (
                                    int i = 0;
                                    i < _filterLabels.length;
                                    i++
                                  ) ...<Widget>[
                                    if (i > 0) const SizedBox(width: 8),
                                    FilterChip(
                                      label: Text(_filterLabels[i]),
                                      selected: _selectedIndex == i,
                                      onSelected: (_) => setState(
                                        () => _selectedIndex = i,
                                      ),
                                      visualDensity: VisualDensity.compact,
                                      showCheckmark: false,
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
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

class _DesktopWorkspace extends StatefulWidget {
  const _DesktopWorkspace({
    required this.desktopLayoutClass,
    required this.sidebarWidth,
    required this.navbarStyle,
    required this.navbarAutohide,
    required this.expandRequestNotifier,
    required this.selectedIndex,
    required this.destinations,
    required this.showOfflineBanner,
    required this.offlineBannerText,
    required this.showPlayer,
    required this.showQueueOverlay,
    required this.hasPlayerOverlay,
    required this.navigationShell,
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.artistId,
    required this.albumId,
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
    required this.onToggleQueue,
    required this.onDismissQueue,
    required this.queueToggleFocusNode,
    required this.queueOverlayKey,
    required this.showLyricsOverlay,
    required this.onToggleLyrics,
    this.onToggleAutohide,
    this.onSystemBack,
  });

  final DesktopLayoutClass desktopLayoutClass;
  final double sidebarWidth;
  final String navbarStyle;
  final bool navbarAutohide;
  final ValueNotifier<int> expandRequestNotifier;
  final int selectedIndex;
  final List<_ShellDestination> destinations;
  final bool showOfflineBanner;
  final String offlineBannerText;
  final bool showPlayer;
  final bool showQueueOverlay;
  final bool hasPlayerOverlay;
  final StatefulNavigationShell navigationShell;
  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
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
  final VoidCallback onToggleQueue;
  final VoidCallback onDismissQueue;
  final FocusNode queueToggleFocusNode;
  final GlobalKey<_QueueOverlayState> queueOverlayKey;
  final bool showLyricsOverlay;
  final VoidCallback onToggleLyrics;
  final VoidCallback? onToggleAutohide;
  final VoidCallback? onSystemBack;

  @override
  State<_DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<_DesktopWorkspace> {
  static const Duration _animDuration = Duration(milliseconds: 280);
  static const Curve _animCurve = Curves.easeOutCubic;
  static const double _collapsedWidth = 4.0;
  static const double _magnetZoneWidth = 40.0;
  static const Duration _collapseDelay = Duration(milliseconds: 500);
  static const Duration _navExpandHoldDuration = Duration(milliseconds: 1600);

  bool _sidebarVisible = true;
  bool _mouseIsOverSidebar = false;
  Timer? _collapseTimer;
  int _lastExpandRequest = 0;

  @override
  void initState() {
    super.initState();
    _sidebarVisible = !widget.navbarAutohide;
    _lastExpandRequest = widget.expandRequestNotifier.value;
    widget.expandRequestNotifier.addListener(_onExpandRequest);
  }

  @override
  void didUpdateWidget(_DesktopWorkspace old) {
    super.didUpdateWidget(old);
    if (old.expandRequestNotifier != widget.expandRequestNotifier) {
      old.expandRequestNotifier.removeListener(_onExpandRequest);
      widget.expandRequestNotifier.addListener(_onExpandRequest);
      _lastExpandRequest = widget.expandRequestNotifier.value;
    }
    if (!widget.navbarAutohide) {
      _collapseTimer?.cancel();
      if (!_sidebarVisible) {
        setState(() => _sidebarVisible = true);
      }
    } else if (!old.navbarAutohide && widget.navbarAutohide) {
      if (!_mouseIsOverSidebar) {
        _scheduleCollapse();
      }
    }
  }

  @override
  void dispose() {
    widget.expandRequestNotifier.removeListener(_onExpandRequest);
    _collapseTimer?.cancel();
    super.dispose();
  }

  void _onExpandRequest() {
    if (!widget.navbarAutohide) return;
    final current = widget.expandRequestNotifier.value;
    if (current == _lastExpandRequest) return;
    _lastExpandRequest = current;
    _collapseTimer?.cancel();
    if (!mounted) return;
    setState(() => _sidebarVisible = true);
    _collapseTimer = Timer(_navExpandHoldDuration, () {
      if (!mounted || _mouseIsOverSidebar) return;
      setState(() => _sidebarVisible = false);
    });
  }

  void _onMouseEnterSidebar(PointerEnterEvent _) {
    if (!widget.navbarAutohide) return;
    _collapseTimer?.cancel();
    _mouseIsOverSidebar = true;
    if (!mounted) return;
    setState(() => _sidebarVisible = true);
  }

  void _onMouseExitSidebar(PointerExitEvent _) {
    if (!widget.navbarAutohide) return;
    _mouseIsOverSidebar = false;
    _scheduleCollapse();
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(_collapseDelay, () {
      if (!mounted || _mouseIsOverSidebar) return;
      setState(() => _sidebarVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final effectiveSidebarWidth = widget.navbarAutohide && !_sidebarVisible
        ? _collapsedWidth
        : widget.sidebarWidth;

    final sidebarContent = Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        child: widget.navbarAutohide && !_sidebarVisible
            ? const SizedBox.expand()
            : SizedBox(
                key: const ValueKey<String>('desktopSidebarRegion'),
                width: widget.sidebarWidth,
                child: Padding(
                  padding: widget.navbarStyle == 'icons'
                      ? const EdgeInsets.fromLTRB(4, 12, 4, 12)
                      : const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: _RailSidebar(
                    navbarStyle: widget.navbarStyle,
                    selectedIndex: widget.selectedIndex,
                    onDestinationSelected: widget.onDestinationSelected,
                    destinations: widget.destinations,
                    showLibrarySubNavigation: widget.showLibrarySubNavigation,
                    allowScrollableRail: widget.allowScrollableRail,
                    selectedLibrarySection: widget.selectedLibrarySection,
                    showLikedLibraryPage: widget.showLikedLibraryPage,
                    showArtistsLibraryPage: widget.showArtistsLibraryPage,
                    showPlaylistsLibraryPage: widget.showPlaylistsLibraryPage,
                    showRadioLibraryPage: widget.showRadioLibraryPage,
                    onLibrarySectionSelected: widget.onLibrarySectionSelected,
                    showPlayer: false,
                    playback: widget.playback,
                    songTitle: widget.songTitle,
                    songArtist: widget.songArtist,
                    coverArtId: widget.coverArtId,
                    coverArtUrl: widget.coverArtUrl,
                    isRadio: widget.playback.isRadioMode,
                    radioArtUrl: widget.playback.radioStation?.nowPlayingArtUrl,
                    onOpenPlayer: widget.onOpenPlayer,
                    navbarAutohide: widget.navbarAutohide,
                    onToggleAutohide: widget.onToggleAutohide,
                  ),
                ),
              ),
      ),
    );

    return Column(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Row(
                  children: <Widget>[
                    FocusTraversalOrder(
                      order: const NumericFocusOrder(10),
                      child: AnimatedContainer(
                        duration: _animDuration,
                        curve: _animCurve,
                        width: effectiveSidebarWidth,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: widget.sidebarWidth,
                            maxWidth: widget.sidebarWidth,
                            child: sidebarContent,
                          ),
                        ),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: colors.outlineVariant.withValues(alpha: 0.35),
                    ),
                    Expanded(
                      child: FocusTraversalOrder(
                        order: const NumericFocusOrder(20),
                        child: SafeArea(
                          left: false,
                          top: false,
                          right: false,
                          child: Column(
                            children: <Widget>[
                              if (widget.showOfflineBanner)
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
                                            widget.offlineBannerText,
                                            style: TextStyle(
                                              color: colors.onErrorContainer,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final width = constraints.maxWidth;
                                    final horizontalInset = switch (widget
                                        .desktopLayoutClass) {
                                      DesktopLayoutClass.compactDesktop => 12.0,
                                      DesktopLayoutClass.standardDesktop =>
                                        (width * 0.018).clamp(14.0, 30.0),
                                      DesktopLayoutClass.ultraWideDesktop =>
                                        (width * 0.022).clamp(18.0, 44.0),
                                    };
                                    const verticalInset = 20.0;

                                    return NavigatorPopHandler<Object?>(
                                      enabled: true,
                                      onPopWithResult: (result) {
                                        if (widget.hasPlayerOverlay) {
                                          widget.onSystemBack?.call();
                                          return;
                                        }
                                        final router = GoRouter.of(context);
                                        if (!router.canPop()) {
                                          return;
                                        }
                                        NavService.clearExitPrompt();
                                        router.pop(result);
                                      },
                                      child: Stack(
                                        children: <Widget>[
                                          Positioned.fill(
                                            child: Padding(
                                              padding: EdgeInsets.fromLTRB(
                                                horizontalInset,
                                                verticalInset,
                                                horizontalInset,
                                                verticalInset,
                                              ),
                                              child: Stack(
                                                children: <Widget>[
                                                  Positioned.fill(
                                                    child:
                                                        widget.navigationShell,
                                                  ),
                                                  if (widget.showLyricsOverlay)
                                                    Positioned.fill(
                                                      child:
                                                          _DesktopLyricsOverlay(
                                                            onClose: widget
                                                                .onToggleLyrics,
                                                          ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          if (widget.showPlayer &&
                                              widget.showQueueOverlay)
                                            Positioned.fill(
                                              child: FocusTraversalOrder(
                                                order: const NumericFocusOrder(
                                                  5,
                                                ),
                                                child: _QueueOverlay(
                                                  key: widget.queueOverlayKey,
                                                  fullscreen: false,
                                                  floatingWindow: true,
                                                  onDismiss:
                                                      widget.onDismissQueue,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    );
                                  },
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
              if (widget.navbarAutohide)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _sidebarVisible
                      ? widget.sidebarWidth
                      : _magnetZoneWidth,
                  child: MouseRegion(
                    opaque: false,
                    onEnter: _onMouseEnterSidebar,
                    onExit: _onMouseExitSidebar,
                  ),
                ),
            ],
          ),
        ),
        if (widget.showPlayer)
          FocusTraversalOrder(
            order: const NumericFocusOrder(30),
            child: _DesktopPlayerBar(
              playback: widget.playback,
              songTitle: widget.songTitle,
              songArtist: widget.songArtist,
              artistId: widget.artistId,
              albumId: widget.albumId,
              coverArtId: widget.coverArtId,
              coverArtUrl: widget.playback.isRadioMode
                  ? widget.playback.radioStation?.nowPlayingArtUrl
                  : widget.coverArtUrl,
              onOpenPlayer: widget.onOpenPlayer,
              onToggleQueue: widget.onToggleQueue,
              queueToggleFocusNode: widget.queueToggleFocusNode,
              lyricsActive: widget.showLyricsOverlay,
              onToggleLyrics: widget.onToggleLyrics,
            ),
          ),
      ],
    );
  }
}

class _DesktopPlayerBar extends ConsumerStatefulWidget {
  const _DesktopPlayerBar({
    required this.playback,
    required this.songTitle,
    required this.songArtist,
    required this.artistId,
    required this.albumId,
    required this.coverArtId,
    required this.coverArtUrl,
    required this.onOpenPlayer,
    required this.onToggleQueue,
    required this.queueToggleFocusNode,
    required this.lyricsActive,
    required this.onToggleLyrics,
  });

  final PlaybackSnapshot playback;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
  final String? albumId;
  final String? coverArtId;
  final String? coverArtUrl;
  final VoidCallback onOpenPlayer;
  final VoidCallback onToggleQueue;
  final FocusNode queueToggleFocusNode;
  final bool lyricsActive;
  final VoidCallback onToggleLyrics;

  @override
  ConsumerState<_DesktopPlayerBar> createState() => _DesktopPlayerBarState();
}

class _DesktopPlayerBarState extends ConsumerState<_DesktopPlayerBar> {
  double? _dragSliderValue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final playback = widget.playback;
    final playbackVolume = ref.watch(playbackVolumeProvider);
    final isPlaying = playback.playing;
    final title = (widget.songTitle == null || widget.songTitle!.trim().isEmpty)
        ? l10n.miniPlayerUnknownTrack
        : widget.songTitle!;
    final artist =
        (widget.songArtist == null || widget.songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : widget.songArtist!;
    final resolvedArtistId = (widget.artistId ?? '').trim();
    final canOpenArtist = resolvedArtistId.isNotEmpty && !playback.isRadioMode;

    final livePosition = ref.watch(playbackPositionProvider).asData?.value;
    final position = livePosition ?? playback.position;
    final duration = playback.duration;
    final durationMs = duration.inMilliseconds;
    final canSeek = !playback.isRadioMode && durationMs > 0;
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

    final preferredMixMode = ref.watch(preferredMixModeProvider);
    final instantMix = ref.watch(instantMixProvider);
    final sameVibes = ref.watch(sameVibesProvider);
    final mixActive = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? instantMix.active
        : sameVibes.active;
    final mixLoading = preferredMixMode == PreferredMixMode.legacyInstantMix
        ? (instantMix.refilling && instantMix.active)
        : (sameVibes.refilling && sameVibes.active);
    final mixSeedSongId = playback.currentSongId;
    final canToggleMix =
        mixSeedSongId != null && mixSeedSongId.trim().isNotEmpty;
    final isRemoteSeedId =
        mixSeedSongId != null && !isServerAddressableSongId(mixSeedSongId);
    final canToggleLegacyMix =
        canToggleMix &&
        !(isRemoteSeedId &&
            preferredMixMode == PreferredMixMode.legacyInstantMix);

    final repeatMode = playback.repeatMode;
    String repeatTooltip;
    IconData repeatIcon;
    switch (repeatMode) {
      case AudioServiceRepeatMode.one:
        repeatTooltip = l10n.nowPlayingRepeatOne;
        repeatIcon = Icons.repeat_one;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        repeatTooltip = l10n.nowPlayingRepeatAll;
        repeatIcon = Icons.repeat;
      case AudioServiceRepeatMode.none:
        repeatTooltip = l10n.nowPlayingRepeatOff;
        repeatIcon = Icons.repeat;
    }
    final isRepeatActive = repeatMode != AudioServiceRepeatMode.none;
    final barColor = Color.alphaBlend(
      colors.primary.withValues(alpha: 0.024),
      colors.surfaceContainerLow,
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Material(
        key: const ValueKey<String>('desktopPlayerBar'),
        color: barColor,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 116,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxWidth = constraints.maxWidth;
                final compactLayout = maxWidth < 980;
                final showQueueAction = maxWidth >= 720;
                final showVolumeControl = maxWidth >= 860;
                final showInlineLikeAction =
                    !playback.isRadioMode && maxWidth >= 760;
                final metadataWidth = compactLayout ? 292.0 : 352.0;
                final metadataTextWidth = compactLayout ? 156.0 : 208.0;
                const likeGapWidth = 8.0;
                const likeSlotWidth = 40.0;
                final controlRailMaxWidth = math
                    .min(760, math.max(280, maxWidth * 0.58))
                    .toDouble();
                final tightHeight = constraints.maxHeight <= 100;
                final denseControls = maxWidth <= 820 || tightHeight;
                final controlButtonExtent = tightHeight
                    ? 36.0
                    : (denseControls ? 40.0 : 44.0);
                final primaryControlExtent = tightHeight
                    ? 44.0
                    : (denseControls ? 48.0 : 54.0);
                final controlIconSize = tightHeight
                    ? 20.0
                    : (denseControls ? 22.0 : 24.0);
                final primaryIconSize = tightHeight
                    ? 24.0
                    : (denseControls ? 26.0 : 28.0);
                final verticalInset = tightHeight
                    ? 4.0
                    : (denseControls ? 6.0 : 8.0);
                final sliderBottomSpacing = tightHeight
                    ? 1.0
                    : (denseControls ? 4.0 : 6.0);
                final timeBottomSpacing = tightHeight
                    ? 0.0
                    : (denseControls ? 2.0 : 4.0);
                final sliderTrackHeight = tightHeight ? 2.5 : 3.0;
                final sliderThumbRadius = tightHeight ? 4.0 : 5.0;
                final sliderOverlayRadius = tightHeight ? 8.0 : 11.0;
                final sliderAreaHeight = tightHeight ? 28.0 : null;
                final controlsAreaHeight = tightHeight
                    ? primaryControlExtent
                    : null;
                final showTimeLabels = !tightHeight;
                final timeStyle = Theme.of(context).textTheme.labelSmall
                    ?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontSize: tightHeight ? 10 : null,
                      height: tightHeight ? 1 : null,
                    );

                Future<void> togglePlayPause() async {
                  final handler = ref.read(audioHandlerProvider);
                  if (handler == null) {
                    return;
                  }
                  if (isPlaying) {
                    await handler.pause();
                  } else {
                    await handler.play();
                  }
                }

                Future<void> skipForwardOrStopRadio() async {
                  final handler = ref.read(audioHandlerProvider);
                  if (handler == null) {
                    return;
                  }
                  if (playback.isRadioMode) {
                    await handler.stopRadio();
                  } else {
                    await handler.skipToNext();
                  }
                }

                void skipBackward() {
                  if (playback.isRadioMode) {
                    return;
                  }
                  unawaited(ref.read(audioHandlerProvider)?.skipToPrevious());
                }

                Future<void> setPlaybackVolume(
                  double rawValue, {
                  required String source,
                  bool logChange = false,
                }) async {
                  final volumeNotifier = ref.read(
                    playbackVolumeProvider.notifier,
                  );
                  final volume = volumeNotifier.setVolume(rawValue);
                  if (logChange) {
                    AppLogger.debug(
                      '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                    );
                  }
                  await ref.read(audioHandlerProvider)?.setVolume(volume);
                }

                Future<void> toggleMute({
                  required String source,
                }) async {
                  final volume = ref
                      .read(playbackVolumeProvider.notifier)
                      .toggleMute();
                  AppLogger.debug(
                    '[ACP_INPUT] volume source=$source value=${volume.toStringAsFixed(2)}',
                  );
                  await ref.read(audioHandlerProvider)?.setVolume(volume);
                }

                final resolvedAlbumId = (widget.albumId ?? '').trim();
                final canOpenAlbum =
                    resolvedAlbumId.isNotEmpty && !playback.isRadioMode;

                Widget coverArtWidget;
                if (widget.coverArtId == null ||
                    widget.coverArtId!.trim().isEmpty) {
                  coverArtWidget = _MiniRemoteArt(
                    artUrl: widget.coverArtUrl,
                    colorScheme: colors,
                    size: compactLayout ? 42 : 48,
                  );
                } else {
                  coverArtWidget = CoverArtImage(
                    coverArtId: widget.coverArtId,
                    size: 200,
                    width: compactLayout ? 42 : 48,
                    height: compactLayout ? 42 : 48,
                    borderRadius: BorderRadius.circular(8),
                  );
                }

                if (canOpenAlbum) {
                  coverArtWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => NavService.goToAlbum(
                        context,
                        ref,
                        resolvedAlbumId,
                      ),
                      child: coverArtWidget,
                    ),
                  );
                } else if (playback.isRadioMode &&
                    (widget.coverArtUrl ?? '').trim().isNotEmpty) {
                  coverArtWidget = MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => showRemoteArtViewer(
                        context,
                        artUrl: widget.coverArtUrl,
                      ),
                      child: coverArtWidget,
                    ),
                  );
                }

                final playerSurface = Padding(
                  padding: EdgeInsets.fromLTRB(
                    compactLayout ? 10 : 14,
                    verticalInset,
                    compactLayout ? 8 : 12,
                    verticalInset,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: metadataWidth,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Row(
                            children: <Widget>[
                              coverArtWidget,
                              SizedBox(width: compactLayout ? 8 : 10),
                              SizedBox(
                                width: metadataTextWidth,
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    // Title — tappable for radio (search songs)
                                    if (playback.isRadioMode &&
                                        (widget.songTitle ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          onTap: () {
                                            ref
                                                .read(
                                                  searchFilterProvider.notifier,
                                                )
                                                .select(
                                                  SearchResultType.songs,
                                                );
                                            NavService.goToSearch(
                                              context,
                                              ref,
                                              widget.songTitle!.trim(),
                                            );
                                          },
                                          child: Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ),
                                      )
                                    else
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                    if (canOpenArtist)
                                      MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: TextButton(
                                          style: TextButton.styleFrom(
                                            padding: EdgeInsets.zero,
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                            visualDensity:
                                                VisualDensity.compact,
                                            alignment: Alignment.centerLeft,
                                            foregroundColor: colors.primary,
                                          ),
                                          onPressed: () =>
                                              NavService.goToArtist(
                                                context,
                                                ref,
                                                resolvedArtistId,
                                              ),
                                          child: Text(
                                            artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: colors.primary,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
                                        ),
                                      )
                                    else if (playback.isRadioMode &&
                                        (widget.songArtist ?? '')
                                            .trim()
                                            .isNotEmpty)
                                      Wrap(
                                        spacing: 0,
                                        runSpacing: 0,
                                        children: [
                                          for (final (i, name) in _splitArtists(
                                            widget.songArtist!,
                                          ).indexed) ...<Widget>[
                                            if (i > 0)
                                              Text(
                                                ', ',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: colors
                                                          .onSurfaceVariant,
                                                    ),
                                              ),
                                            MouseRegion(
                                              cursor: SystemMouseCursors.click,
                                              child: GestureDetector(
                                                onTap: () {
                                                  ref
                                                      .read(
                                                        searchFilterProvider
                                                            .notifier,
                                                      )
                                                      .select(
                                                        SearchResultType
                                                            .artists,
                                                      );
                                                  NavService.goToSearch(
                                                    context,
                                                    ref,
                                                    name,
                                                  );
                                                },
                                                child: Text(
                                                  name,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: colors.primary,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      )
                                    else
                                      Text(
                                        artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: colors.onSurfaceVariant,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: likeGapWidth),
                              SizedBox(
                                width: likeSlotWidth,
                                child: showInlineLikeAction
                                    ? IconButton(
                                        tooltip: playback.isCurrentSongLiked
                                            ? l10n.actionLiked
                                            : l10n.actionLike,
                                        visualDensity: VisualDensity.compact,
                                        style: IconButton.styleFrom(
                                          minimumSize: const Size(38, 38),
                                          padding: const EdgeInsets.all(4),
                                        ),
                                        onPressed: () {
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
                                              ? colors.primary
                                              : null,
                                        ),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: controlRailMaxWidth,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: <Widget>[
                                if (!playback.isRadioMode)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom: sliderBottomSpacing,
                                    ),
                                    child: SizedBox(
                                      height: sliderAreaHeight,
                                      child: canSeek
                                          ? SliderTheme(
                                              data: SliderTheme.of(context)
                                                  .copyWith(
                                                    padding: EdgeInsets.zero,
                                                    trackHeight:
                                                        sliderTrackHeight,
                                                    thumbShape:
                                                        RoundSliderThumbShape(
                                                          enabledThumbRadius:
                                                              sliderThumbRadius,
                                                        ),
                                                    overlayShape:
                                                        RoundSliderOverlayShape(
                                                          overlayRadius:
                                                              sliderOverlayRadius,
                                                        ),
                                                  ),
                                              child: Slider(
                                                value: sliderValue,
                                                max: sliderMax,
                                                onChangeStart: (value) {
                                                  setState(() {
                                                    _dragSliderValue = value;
                                                  });
                                                },
                                                onChanged: (value) {
                                                  setState(() {
                                                    _dragSliderValue = value;
                                                  });
                                                },
                                                onChangeEnd: (value) {
                                                  setState(() {
                                                    _dragSliderValue = null;
                                                  });
                                                  unawaited(
                                                    ref
                                                        .read(
                                                          audioHandlerProvider,
                                                        )
                                                        ?.seek(
                                                          Duration(
                                                            milliseconds: value
                                                                .round(),
                                                          ),
                                                        ),
                                                  );
                                                },
                                              ),
                                            )
                                          : Align(
                                              alignment: Alignment.center,
                                              child: LinearProgressIndicator(
                                                value: playback.isRadioMode
                                                    ? (playback.processingState ==
                                                                  AudioProcessingState
                                                                      .loading ||
                                                              playback.processingState ==
                                                                  AudioProcessingState
                                                                      .buffering
                                                          ? null
                                                          : 0.0)
                                                    : progress,
                                                minHeight: 3,
                                                color: colors.primary,
                                                backgroundColor: colors.primary
                                                    .withValues(alpha: 0.12),
                                              ),
                                            ),
                                    ),
                                  ),
                                if (!playback.isRadioMode && showTimeLabels)
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      4,
                                      0,
                                      4,
                                      timeBottomSpacing,
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: <Widget>[
                                        Text(
                                          _formatMiniPlayerDuration(
                                            seekPreviewPosition,
                                          ),
                                          style: timeStyle,
                                        ),
                                        Text(
                                          canSeek
                                              ? _formatMiniPlayerDuration(
                                                  duration,
                                                )
                                              : '--:--',
                                          style: timeStyle,
                                        ),
                                      ],
                                    ),
                                  ),
                                SizedBox(
                                  height: controlsAreaHeight,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          tooltip:
                                              l10n.nowPlayingInstantMixLabel,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed:
                                              !playback.isRadioMode &&
                                                  canToggleLegacyMix
                                              ? () => unawaited(
                                                  togglePreferredMixMode(
                                                    ref,
                                                    seedSongId: mixSeedSongId,
                                                  ),
                                                )
                                              : null,
                                          icon: mixLoading
                                              ? SizedBox(
                                                  width: 20,
                                                  height: 20,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color: mixActive
                                                        ? colors.primary
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                )
                                              : Icon(
                                                  mixActive
                                                      ? Icons.explore
                                                      : Icons.explore_outlined,
                                                  color: mixActive
                                                      ? colors.primary
                                                      : null,
                                                ),
                                        ),
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          tooltip: l10n.nowPlayingPrevious,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: skipBackward,
                                          icon: const Icon(
                                            Icons.skip_previous_rounded,
                                          ),
                                        ),
                                      IconButton.filledTonal(
                                        tooltip: isPlaying
                                            ? l10n.miniPlayerPause
                                            : l10n.miniPlayerPlay,
                                        style: IconButton.styleFrom(
                                          minimumSize: Size.square(
                                            primaryControlExtent,
                                          ),
                                          maximumSize: Size.square(
                                            primaryControlExtent,
                                          ),
                                          shape: const CircleBorder(),
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () =>
                                            unawaited(togglePlayPause()),
                                        icon: Icon(
                                          isPlaying
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          size: primaryIconSize,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: playback.isRadioMode
                                            ? l10n.radioStopStation
                                            : l10n.miniPlayerSkipNext,
                                        iconSize: controlIconSize,
                                        style: IconButton.styleFrom(
                                          minimumSize: Size.square(
                                            controlButtonExtent,
                                          ),
                                          maximumSize: Size.square(
                                            controlButtonExtent,
                                          ),
                                          shape: const CircleBorder(),
                                          padding: EdgeInsets.zero,
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => unawaited(
                                          skipForwardOrStopRadio(),
                                        ),
                                        icon: Icon(
                                          playback.isRadioMode
                                              ? Icons.stop_rounded
                                              : Icons.skip_next_rounded,
                                        ),
                                      ),
                                      if (!playback.isRadioMode)
                                        IconButton(
                                          tooltip: repeatTooltip,
                                          iconSize: controlIconSize,
                                          style: IconButton.styleFrom(
                                            minimumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            maximumSize: Size.square(
                                              controlButtonExtent,
                                            ),
                                            shape: const CircleBorder(),
                                            padding: EdgeInsets.zero,
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: playback.isRadioMode
                                              ? null
                                              : () {
                                                  final handler = ref.read(
                                                    audioHandlerProvider,
                                                  );
                                                  final next =
                                                      switch (repeatMode) {
                                                        AudioServiceRepeatMode
                                                            .none =>
                                                          AudioServiceRepeatMode
                                                              .all,
                                                        AudioServiceRepeatMode
                                                            .all =>
                                                          AudioServiceRepeatMode
                                                              .one,
                                                        AudioServiceRepeatMode
                                                            .one =>
                                                          AudioServiceRepeatMode
                                                              .none,
                                                        AudioServiceRepeatMode
                                                            .group =>
                                                          AudioServiceRepeatMode
                                                              .none,
                                                      };
                                                  unawaited(
                                                    handler?.setRepeatMode(
                                                      next,
                                                    ),
                                                  );
                                                },
                                          icon: Icon(
                                            repeatIcon,
                                            color: isRepeatActive
                                                ? colors.primary
                                                : null,
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
                      SizedBox(
                        width: showVolumeControl ? 344 : 152,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            if (!playback.isRadioMode)
                              IconButton(
                                tooltip: l10n.nowPlayingLyrics,
                                icon: Icon(
                                  Icons.lyrics_outlined,
                                  color: widget.lyricsActive
                                      ? colors.primary
                                      : null,
                                ),
                                onPressed: widget.onToggleLyrics,
                              ),
                            if (showVolumeControl) ...<Widget>[
                              DesktopVolumeSlider(
                                key: const ValueKey<String>(
                                  'desktopPlayerVolumeSlider',
                                ),
                                volume: playbackVolume,
                                onChanged: (value) => unawaited(
                                  setPlaybackVolume(
                                    value,
                                    source: 'desktop_player_bar_live',
                                  ),
                                ),
                                onChangeEnd: (value) => unawaited(
                                  setPlaybackVolume(
                                    value,
                                    source: 'desktop_player_bar_settle',
                                    logChange: true,
                                  ),
                                ),
                                onMuteToggle: () => unawaited(
                                  toggleMute(source: 'desktop_player_icon'),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (showQueueAction && !playback.isRadioMode)
                              IconButton(
                                key: const ValueKey<String>(
                                  'desktopQueueButton',
                                ),
                                focusNode: widget.queueToggleFocusNode,
                                tooltip: l10n.queueTitle,
                                onPressed: widget.onToggleQueue,
                                icon: const Icon(
                                  Icons.queue_music_outlined,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );

                return playerSurface;
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _QueueOverlay extends StatefulWidget {
  const _QueueOverlay({
    super.key,
    required this.onDismiss,
    this.fullscreen = false,
    this.floatingWindow = false,
  });

  final VoidCallback onDismiss;
  final bool fullscreen;
  final bool floatingWindow;

  @override
  State<_QueueOverlay> createState() => _QueueOverlayState();
}

class _QueueOverlayState extends State<_QueueOverlay>
    with SingleTickerProviderStateMixin {
  static const double _sheetHeightFactor = 0.95;
  static const Duration _openDuration = Duration(milliseconds: 230);
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
  bool _queueItemSwiping = false;
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
      duration: _openDuration,
      reverseDuration: _closeDuration,
    );
    _controller.animateTo(1, curve: Curves.easeOutCubic);
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
    _controller
        .animateBack(0, duration: _closeDuration, curve: Curves.easeInCubic)
        .whenComplete(widget.onDismiss);
  }

  void dismissAnimated() => _dismiss();

  bool get isDismissing => _dismissing;

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

  void _setQueueItemSwiping(bool value) {
    if (_queueItemSwiping == value) return;
    // If an item swipe starts while the sheet was tracking a drag, reset it.
    if (value) {
      _activePointer = null;
      _velocityTracker = null;
      _setDraggingSheet(false);
    }
    setState(() => _queueItemSwiping = value);
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
    if (_queueItemSwiping) return; // item swipe has claimed this gesture
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
        final scrimOpacity = Curves.easeOutCubic.transform(progress) * 0.45;
        final useFloatingWindow = widget.floatingWindow && !widget.fullscreen;
        final heightFactor = widget.fullscreen
            ? 1.0
            : (useFloatingWindow ? 0.72 : _sheetHeightFactor);

        final queueContent = widget.fullscreen
            ? Material(
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  child: QueueSheet(
                    scrollController: _scrollController,
                    sheetDragActive: _draggingSheet,
                    onReorderDragChanged: _setQueueReorderActive,
                    onItemSwipeActiveChanged: _setQueueItemSwiping,
                    onClose: _dismiss,
                  ),
                ),
              )
            : QueueSheet(
                scrollController: _scrollController,
                sheetDragActive: _draggingSheet,
                onReorderDragChanged: _setQueueReorderActive,
                onItemSwipeActiveChanged: _setQueueItemSwiping,
                onClose: _dismiss,
                embeddedMode: useFloatingWindow,
              );

        final queueSurface = useFloatingWindow
            ? Material(
                color: Theme.of(context).colorScheme.surface,
                elevation: 14,
                borderRadius: BorderRadius.circular(18),
                clipBehavior: Clip.antiAlias,
                child: queueContent,
              )
            : queueContent;

        return FocusScope(
          autofocus: true,
          child: Stack(
            children: <Widget>[
              if (!widget.fullscreen)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: progress < 0.01,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _dismiss,
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: scrimOpacity),
                      ),
                    ),
                  ),
                ),
              // Sheet — slides up from the bottom with 1:1 finger tracking.
              if (useFloatingWindow)
                Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: 320,
                        maxWidth: math.min(
                          560,
                          MediaQuery.sizeOf(context).width * 0.46,
                        ),
                      ),
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
                              child: queueSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              else
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
                          child: queueSurface,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
    this.navbarStyle = 'comfortable',
    this.songTitle,
    this.songArtist,
    this.artistId,
    this.coverArtId,
    this.coverArtUrl,
    this.isRadio = false,
    this.radioArtUrl,
    this.navbarAutohide = false,
    this.onToggleAutohide,
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
  final String? artistId;
  final String? coverArtId;
  final String? coverArtUrl;
  final bool isRadio;
  final String? radioArtUrl;
  final VoidCallback onOpenPlayer;
  final String navbarStyle;
  final bool navbarAutohide;
  final VoidCallback? onToggleAutohide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iconsOnly = navbarStyle == 'icons';
    final compact = navbarStyle == 'compact';
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (onToggleAutohide != null)
            Align(
              alignment: iconsOnly ? Alignment.center : Alignment.centerRight,
              child: SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  icon: Icon(
                    navbarAutohide
                        ? Icons.lock_open_rounded
                        : Icons.lock_rounded,
                    size: 16,
                  ),
                  tooltip: navbarAutohide
                      ? AppLocalizations.of(context)!.desktopNavbarLockTooltip
                      : AppLocalizations.of(
                          context,
                        )!.desktopNavbarUnlockTooltip,
                  onPressed: onToggleAutohide,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    maximumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final navTileEstimatedHeight = compact ? 52.0 : 64.0;
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
                    !iconsOnly &&
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
                        iconsOnly: iconsOnly,
                        compact: compact,
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
                        artistId: artistId,
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
    this.iconsOnly = false,
    this.compact = false,
  });

  final _ShellDestination destination;
  final bool selected;
  final VoidCallback onTap;
  final bool iconsOnly;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
      color: selected
          ? colorScheme.onSecondaryContainer
          : colorScheme.onSurfaceVariant,
    );
    final tilePadding = iconsOnly
        ? const EdgeInsets.symmetric(horizontal: 4, vertical: 12)
        : compact
        ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
        : const EdgeInsets.symmetric(horizontal: 16, vertical: 14);

    return Material(
      color: selected
          ? colorScheme.secondaryContainer.withValues(alpha: 0.9)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: tilePadding,
          child: Row(
            mainAxisAlignment: iconsOnly
                ? MainAxisAlignment.center
                : MainAxisAlignment.start,
            children: <Widget>[
              Icon(
                destination.icon,
                size: 24,
                color: selected
                    ? colorScheme.onSecondaryContainer
                    : colorScheme.onSurfaceVariant,
              ),
              if (!iconsOnly) ...<Widget>[
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
    this.artistId,
    this.coverArtId,
    this.coverArtUrl,
    this.isRadio = false,
    this.radioArtUrl,
  });

  final PlaybackSnapshot playback;
  final VoidCallback onOpenPlayer;
  final String? songTitle;
  final String? songArtist;
  final String? artistId;
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
    final livePosition = ref.watch(playbackPositionProvider).asData?.value;
    final isPlaying = playback.playing;
    final position = livePosition ?? playback.position;
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
    final artistDisplay =
        (widget.songArtist == null || widget.songArtist!.trim().isEmpty)
        ? l10n.miniPlayerUnknownArtist
        : widget.songArtist!;
    final resolvedArtistId = (widget.artistId ?? '').trim();
    final canNavigateArtist = resolvedArtistId.isNotEmpty && !widget.isRadio;
    const compactButtonConstraints = BoxConstraints(
      minWidth: 46,
      minHeight: 46,
    );

    final fullMiniPlayer = KeyedSubtree(
      key: const ValueKey<String>('railMiniPlayer'),
      child: Align(
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
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Text(
                                        (widget.songTitle == null ||
                                                widget.songTitle!
                                                    .trim()
                                                    .isEmpty)
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
                                      canNavigateArtist
                                          ? GestureDetector(
                                              behavior: HitTestBehavior.opaque,
                                              onTap: () =>
                                                  NavService.goToArtist(
                                                    context,
                                                    ref,
                                                    resolvedArtistId,
                                                  ),
                                              child: MouseRegion(
                                                cursor:
                                                    SystemMouseCursors.click,
                                                child: Text(
                                                  artistDisplay,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        fontSize: 12,
                                                        color: cs.primary,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                      ),
                                                ),
                                              ),
                                            )
                                          : Text(
                                              artistDisplay,
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
                            LayoutBuilder(
                              builder: (context, controlsConstraints) {
                                final ultraCompact =
                                    controlsConstraints.maxWidth < 150;
                                final controls = <Widget>[
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
                                    icon: const Icon(
                                      Icons.skip_previous_rounded,
                                    ),
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
                                  if (!ultraCompact)
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
                                ];
                                return SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: controls,
                                  ),
                                );
                              },
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
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
    final livePosition = ref.watch(playbackPositionProvider).asData?.value;
    final position = livePosition ?? playback.position;
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

/// Fullscreen lyrics overlay shown inside the desktop content area (excluding
/// the sidebar and the bottom player bar).
class _DesktopLyricsOverlay extends ConsumerWidget {
  const _DesktopLyricsOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final playback = ref.watch(playerStateProvider);
    final songId = playback.currentSongId;
    final position =
        ref.watch(playbackPositionProvider).asData?.value ?? playback.position;

    return Material(
      color: colors.surface,
      child: Column(
        children: <Widget>[
          // ── Header bar ──────────────────────────────────────────────
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: colors.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
              child: Row(
                children: <Widget>[
                  Icon(Icons.lyrics_outlined, color: colors.primary, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    l10n.nowPlayingLyrics,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
          // ── Lyrics content ──────────────────────────────────────────
          Expanded(
            child: songId == null || songId.trim().isEmpty
                ? Center(
                    child: Text(
                      l10n.lyricsNoneAvailable,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: colors.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : _DesktopLyricsContent(songId: songId, position: position),
          ),
        ],
      ),
    );
  }
}

class _DesktopLyricsContent extends ConsumerWidget {
  const _DesktopLyricsContent({
    required this.songId,
    required this.position,
  });

  final String songId;
  final Duration position;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    final lyricsAsync = ref.watch(lyricsProvider(songId));

    return lyricsAsync.when(
      data: (resolution) => LyricsDisplayWidget(
        lyrics: resolution.lyrics,
        currentPosition: position,
        onSeek: (seekPosition) {
          unawaited(ref.read(audioHandlerProvider)?.seek(seekPosition));
        },
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) {
        final message = l10n.lyricsNoneAvailable;
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                message,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: colors.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => ref.invalidate(lyricsProvider(songId)),
                icon: const Icon(Icons.refresh),
                label: Text(l10n.commonRetry),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Animates the bottom player sheet in/out with a slide-from-bottom transition.
///
/// When [showPlayer] transitions to `true`, the child slides up from below
/// the viewport. When it transitions to `false`, the child slides back down
/// and is then removed from the tree.
class _SlideUpPlayerTransition extends StatefulWidget {
  const _SlideUpPlayerTransition({
    required this.showPlayer,
    required this.child,
  });

  final bool showPlayer;
  final Widget child;

  @override
  State<_SlideUpPlayerTransition> createState() =>
      _SlideUpPlayerTransitionState();
}

class _SlideUpPlayerTransitionState extends State<_SlideUpPlayerTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
      vsync: this,
    );
    _slideAnimation =
        Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        );
    if (widget.showPlayer) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(_SlideUpPlayerTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showPlayer != oldWidget.showPlayer) {
      if (widget.showPlayer) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (_controller.isDismissed) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          left: 0,
          child: IgnorePointer(
            ignoring: !widget.showPlayer,
            child: SlideTransition(
              position: _slideAnimation,
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
