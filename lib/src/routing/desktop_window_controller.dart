import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

enum DesktopWindowMode { desktop, miniPlayer }

enum DesktopWindowTransitionDirection { enterMiniPlayer, exitMiniPlayer }

@immutable
class DesktopWindowTransitionRequest {
  const new({required this.direction, required this.viewportSize});

  final DesktopWindowTransitionDirection direction;
  final Size viewportSize;
}

@immutable
class DesktopWindowSnapshot {
  const new(this.bounds);

  final Rect bounds;

  Map<String, double> toJson() => <String, double>{
    'x': bounds.left,
    'y': bounds.top,
    'width': bounds.width,
    'height': bounds.height,
  };

  static DesktopWindowSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    final width = (raw['width'] as num?)?.toDouble();
    final height = (raw['height'] as num?)?.toDouble();
    if (x == null || y == null || width == null || height == null) return null;
    if (width <= 0 || height <= 0) return null;
    return DesktopWindowSnapshot(Rect.fromLTWH(x, y, width, height));
  }
}

@immutable
class DesktopWindowStateRecord {
  const new({
    required this.version,
    required this.activeMode,
    this.normalBounds,
    this.normalWasMaximized = false,
    this.miniBounds,
    this.miniAlwaysOnTop = false,
  });

  const new defaults()
    : version = currentVersion,
      activeMode = DesktopWindowMode.desktop,
      normalBounds = null,
      normalWasMaximized = false,
      miniBounds = null,
      miniAlwaysOnTop = false;

  static const int currentVersion = 3;

  final int version;
  final DesktopWindowMode activeMode;
  final DesktopWindowSnapshot? normalBounds;
  final bool normalWasMaximized;
  final DesktopWindowSnapshot? miniBounds;
  final bool miniAlwaysOnTop;

  DesktopWindowStateRecord copyWith({
    int? version,
    DesktopWindowMode? activeMode,
    DesktopWindowSnapshot? normalBounds,
    bool? normalWasMaximized,
    DesktopWindowSnapshot? miniBounds,
    bool? miniAlwaysOnTop,
  }) {
    return DesktopWindowStateRecord(
      version: version ?? this.version,
      activeMode: activeMode ?? this.activeMode,
      normalBounds: normalBounds ?? this.normalBounds,
      normalWasMaximized: normalWasMaximized ?? this.normalWasMaximized,
      miniBounds: miniBounds ?? this.miniBounds,
      miniAlwaysOnTop: miniAlwaysOnTop ?? this.miniAlwaysOnTop,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': currentVersion,
    'activeMode': activeMode.name,
    'normalBounds': normalBounds?.toJson(),
    'normalWasMaximized': normalWasMaximized,
    'miniBounds': miniBounds?.toJson(),
    'miniAlwaysOnTop': miniAlwaysOnTop,
  };

  static DesktopWindowStateRecord fromJson(Object? raw) {
    if (raw is! Map) return const DesktopWindowStateRecord.defaults();

    final legacySnapshot = DesktopWindowSnapshot.fromJson(raw);
    if (legacySnapshot != null && raw['version'] == null) {
      return DesktopWindowStateRecord(
        version: 1,
        activeMode: DesktopWindowMode.desktop,
        normalBounds: legacySnapshot,
      );
    }

    final modeName = raw['activeMode'] as String?;
    final mode = switch (modeName) {
      'miniPlayer' || 'focusPlayer' => DesktopWindowMode.miniPlayer,
      _ => DesktopWindowMode.desktop,
    };
    return DesktopWindowStateRecord(
      version: (raw['version'] as num?)?.toInt() ?? 1,
      activeMode: mode,
      normalBounds: DesktopWindowSnapshot.fromJson(raw['normalBounds']),
      normalWasMaximized: raw['normalWasMaximized'] as bool? ?? false,
      miniBounds: DesktopWindowSnapshot.fromJson(
        raw['miniBounds'] ?? raw['focusBounds'],
      ),
      miniAlwaysOnTop: raw['miniAlwaysOnTop'] as bool? ?? false,
    );
  }
}

abstract class WindowManagerAdapter {
  Future<void> ensureInitialized();
  void addListener(WindowListener listener);
  void removeListener(WindowListener listener);
  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function() callback,
  );
  Future<void> setMinimumSize(Size size);
  Future<void> setMaximumSize(Size size);
  Future<void> setAspectRatio(double aspectRatio);
  Future<void> setResizable(bool resizable);
  Future<void> setAlwaysOnTop(bool alwaysOnTop);
  Future<void> setPreventClose(bool preventClose);
  Future<void> close();
  Future<void> setBounds(Rect bounds);
  Future<Rect> getBounds();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> center();
  Future<void> show();
  Future<void> focus();
}

class WindowManagerDesktopWindowAdapter implements WindowManagerAdapter {
  const new();

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  void addListener(WindowListener listener) =>
      windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);

  @override
  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function() callback,
  ) => windowManager.waitUntilReadyToShow(options, callback);

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  Future<void> setMaximumSize(Size size) => windowManager.setMaximumSize(size);

  @override
  Future<void> setAspectRatio(double aspectRatio) =>
      windowManager.setAspectRatio(aspectRatio);

  @override
  Future<void> setResizable(bool resizable) =>
      windowManager.setResizable(resizable);

  @override
  Future<void> setAlwaysOnTop(bool alwaysOnTop) =>
      windowManager.setAlwaysOnTop(alwaysOnTop);

  @override
  Future<void> setPreventClose(bool preventClose) =>
      windowManager.setPreventClose(preventClose);

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> setBounds(Rect bounds) => windowManager.setBounds(bounds);

  @override
  Future<Rect> getBounds() => windowManager.getBounds();

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> center() => windowManager.center();

  @override
  Future<void> show() => windowManager.show();

  @override
  Future<void> focus() => windowManager.focus();
}

abstract class ScreenRetrieverAdapter {
  void addListener(ScreenListener listener);
  void removeListener(ScreenListener listener);
  Future<List<Display>> getAllDisplays();
}

class SystemScreenRetrieverAdapter implements ScreenRetrieverAdapter {
  const new();

  @override
  void addListener(ScreenListener listener) =>
      screenRetriever.addListener(listener);

  @override
  void removeListener(ScreenListener listener) =>
      screenRetriever.removeListener(listener);

  @override
  Future<List<Display>> getAllDisplays() => screenRetriever.getAllDisplays();
}

class DesktopWindowController extends ChangeNotifier
    with WindowListener, ScreenListener {
  new({
    required this._desktopRuntime,
    required this._stateFile,
    required SettingsRepository this._settingsRepository,
    WindowManagerAdapter? adapter,
    ScreenRetrieverAdapter? screenAdapter,
    bool? alwaysOnTopSupported,
  }) : _adapter = adapter ?? const WindowManagerDesktopWindowAdapter(),
       _alwaysOnTopSupportedOverride = alwaysOnTopSupported,
       _screenAdapter =
           screenAdapter ??
           (adapter == null ? const SystemScreenRetrieverAdapter() : null);

  new fallback({this._desktopRuntime = false})
    : _stateFile = File(''),
      _settingsRepository = null,
      _adapter = null,
      _alwaysOnTopSupportedOverride = null,
      _screenAdapter = null;

  static const Size normalMinSize = kDesktopMiniPlayerMinimumSize;
  static const Size miniDefaultSize = kDesktopMiniPlayerDefaultSize;
  static const Size miniMinSize = kDesktopMiniPlayerMinimumSize;
  static const Duration resizeSettleInterval = Duration(milliseconds: 400);
  static const Duration _persistDebounceInterval = Duration(milliseconds: 450);

  final bool _desktopRuntime;
  final File _stateFile;
  final SettingsRepository? _settingsRepository;
  final WindowManagerAdapter? _adapter;
  final bool? _alwaysOnTopSupportedOverride;
  final ScreenRetrieverAdapter? _screenAdapter;

  Timer? _persistDebounce;
  Timer? _viewportDebounce;
  DesktopWindowMode _mode = DesktopWindowMode.desktop;
  DesktopWindowStateRecord _stateRecord =
      const DesktopWindowStateRecord.defaults();
  DesktopWindowTransitionRequest? _transitionRequest;
  Size? _lastViewportSize;
  Rect? _currentWorkArea;
  bool _isInitialized = false;
  bool _isApplyingMode = false;
  bool _isClosing = false;
  bool _miniAlwaysOnTop = false;
  String _restorationSource = 'fallback';
  bool _lastPersistenceCompleted = false;

  bool get desktopRuntime => _desktopRuntime;
  bool get isInitialized => _isInitialized;
  bool get isApplyingMode => _isApplyingMode;
  DesktopWindowMode get mode => _mode;
  bool get isMiniPlayerMode => _mode == DesktopWindowMode.miniPlayer;
  int get stateRecordVersion => _stateRecord.version;
  String get restorationSource => _restorationSource;
  bool get lastPersistenceCompleted => _lastPersistenceCompleted;

  /// Whether the platform can honour an always-on-top request.
  ///
  /// GTK's `keep_above` request is deliberately not exposed as a working
  /// feature on Linux Wayland: Wayland gives the compositor sole control over
  /// normal-window stacking, so accepting the preference there would leave a
  /// pin that looks enabled but cannot keep the window above another app.
  /// Test and fallback controllers remain capable so the Mini Player surface
  /// can exercise its normal control path without a native window.
  bool get supportsMiniAlwaysOnTop =>
      _alwaysOnTopSupportedOverride ??
      !(_desktopRuntime &&
          _adapter is WindowManagerDesktopWindowAdapter &&
          Platform.isLinux &&
          _isWaylandSession);

  /// The effective state, rather than a preference that the current compositor
  /// cannot apply. The stored preference is retained for a later supported
  /// desktop session.
  bool get miniAlwaysOnTop => supportsMiniAlwaysOnTop && _miniAlwaysOnTop;
  DesktopWindowTransitionRequest? get transitionRequest => _transitionRequest;
  Rect? get currentWorkArea => _currentWorkArea;
  bool get desktopViewAvailable =>
      _currentWorkArea == null || supportsDesktopView(_currentWorkArea!.size);

  static Future<DesktopWindowController?> bootstrap({
    required bool desktopRuntime,
    required SettingsRepository settingsRepository,
    WindowManagerAdapter? adapter,
    ScreenRetrieverAdapter? screenAdapter,
  }) async {
    if (!desktopRuntime) return null;
    final supportDir = await getApplicationSupportDirectory();
    final controller = DesktopWindowController(
      desktopRuntime: desktopRuntime,
      stateFile: File(
        '${supportDir.path}${Platform.pathSeparator}window_state.json',
      ),
      settingsRepository: settingsRepository,
      adapter: adapter,
      screenAdapter: screenAdapter,
    );
    await controller.initialize();
    return controller;
  }

  Future<void> initialize() async {
    if (!_desktopRuntime || _isInitialized) return;
    final adapter = _adapter;
    if (adapter == null) {
      _isInitialized = true;
      notifyListeners();
      return;
    }

    await adapter.ensureInitialized();
    await adapter.setPreventClose(true);
    adapter.addListener(this);
    _screenAdapter?.addListener(this);
    _stateRecord = await _readStateRecord();
    final legacyFocusEnabled =
        (await _settingsRepository?.getSettings())
            ?.desktopFocusPlayerModeEnabled ??
        false;
    if (legacyFocusEnabled ||
        _stateRecord.activeMode == DesktopWindowMode.miniPlayer) {
      AppLogger.info(
        '[DESKTOP_WINDOW] starting in Desktop View; retained Mini Player '
        'state is used only for a later user-initiated switch.',
      );
    }
    // Mini Player is a temporary presentation, never a startup destination.
    // Its saved bounds and pin preference remain available, while Desktop
    // bounds are restored independently even when the app last closed mini.
    _mode = DesktopWindowMode.desktop;
    _miniAlwaysOnTop = _stateRecord.miniAlwaysOnTop;
    _stateRecord = _stateRecord.copyWith(
      version: DesktopWindowStateRecord.currentVersion,
      activeMode: _mode,
    );

    final savedBounds = _stateRecord.normalBounds?.bounds;
    final normalizedBounds = _normalizeDesktopBounds(savedBounds);
    final startupBounds = await _clampToVisibleWorkArea(normalizedBounds);
    _restorationSource = savedBounds == null
        ? 'fallback'
        : startupBounds == normalizedBounds
        ? 'saved'
        : 'clamped';
    final options = WindowOptions(
      minimumSize: normalMinSize,
      size: startupBounds.size,
      center: savedBounds == null,
    );

    await adapter.waitUntilReadyToShow(options, () async {
      await _applyCommonWindowConstraints();
      await adapter.setAlwaysOnTop(false);
      await adapter.setBounds(startupBounds);
      if (savedBounds == null) await adapter.center();
      if (_mode == DesktopWindowMode.desktop &&
          _stateRecord.normalWasMaximized) {
        await adapter.maximize();
      }
      await adapter.show();
      await adapter.focus();
    });

    _isInitialized = true;
    await _persistCurrentState(reason: 'initialize');
    notifyListeners();
    AppLogger.info('[DESKTOP_WINDOW] initialized mode=${_mode.name}');
  }

  void updateViewportSize(Size viewportSize) {
    if (!_desktopRuntime || viewportSize.isEmpty) return;
    if (_lastViewportSize == viewportSize && _transitionRequest != null) return;
    _lastViewportSize = viewportSize;
    _viewportDebounce?.cancel();

    final miniBelowMinimum =
        _mode == DesktopWindowMode.miniPlayer &&
        !supportsMiniPlayer(viewportSize);
    if (miniBelowMinimum) {
      if (_transitionRequest != null) {
        _transitionRequest = null;
        notifyListeners();
      }
      _viewportDebounce = Timer(resizeSettleInterval, () {
        final size = _lastViewportSize;
        if (_mode != DesktopWindowMode.miniPlayer ||
            size == null ||
            supportsMiniPlayer(size)) {
          return;
        }
        unawaited(_restoreBoundsForCurrentMode());
      });
      return;
    }

    final wantsMini =
        _mode == DesktopWindowMode.desktop &&
        !supportsDesktopView(viewportSize);
    final wantsDesktop =
        _mode == DesktopWindowMode.miniPlayer &&
        supportsDesktopView(viewportSize);
    if (!wantsMini && !wantsDesktop) {
      if (_transitionRequest != null) {
        _transitionRequest = null;
        notifyListeners();
      }
      return;
    }

    _viewportDebounce = Timer(resizeSettleInterval, () {
      if (_isApplyingMode) return;
      final size = _lastViewportSize;
      if (size == null) return;
      final direction = _mode == DesktopWindowMode.desktop
          ? DesktopWindowTransitionDirection.enterMiniPlayer
          : DesktopWindowTransitionDirection.exitMiniPlayer;
      _transitionRequest = DesktopWindowTransitionRequest(
        direction: direction,
        viewportSize: size,
      );
      notifyListeners();
    });
  }

  Future<void> resolveTransition({required bool switchMode}) async {
    final request = _transitionRequest;
    if (request == null) return;
    _transitionRequest = null;
    if (switchMode) {
      await setMiniPlayerMode(
        request.direction == DesktopWindowTransitionDirection.enterMiniPlayer,
      );
      return;
    }
    await _restoreBoundsForCurrentMode();
    notifyListeners();
  }

  Future<void> setMiniPlayerMode(bool enabled) async {
    if (!_desktopRuntime || _isApplyingMode) return;
    if (!enabled && !desktopViewAvailable) return;
    final target = enabled
        ? DesktopWindowMode.miniPlayer
        : DesktopWindowMode.desktop;
    if (_mode == target && _isInitialized) return;
    final adapter = _adapter;
    if (adapter == null) {
      _mode = target;
      _transitionRequest = null;
      notifyListeners();
      return;
    }

    _isApplyingMode = true;
    _transitionRequest = null;
    notifyListeners();
    try {
      if (enabled) {
        await _enterMiniPlayerMode();
      } else {
        await _exitMiniPlayerMode();
      }
      await _persistCurrentState(reason: enabled ? 'enter_mini' : 'exit_mini');
    } finally {
      _isApplyingMode = false;
      notifyListeners();
    }
  }

  Future<void> toggleMiniPlayerMode() => setMiniPlayerMode(!isMiniPlayerMode);

  Future<void> setMiniAlwaysOnTop(bool enabled) async {
    if (enabled && !supportsMiniAlwaysOnTop) {
      AppLogger.info(
        '[DESKTOP_WINDOW] Mini Player always-on-top is unavailable on '
        'Linux Wayland.',
      );
      notifyListeners();
      return;
    }
    if (_miniAlwaysOnTop == enabled) return;
    _miniAlwaysOnTop = enabled;
    _stateRecord = _stateRecord.copyWith(miniAlwaysOnTop: enabled);
    if (isMiniPlayerMode) await _adapter?.setAlwaysOnTop(enabled);
    await _persistCurrentState(reason: 'mini_always_on_top');
    notifyListeners();
  }

  Future<Rect?> getCurrentBounds() async =>
      _adapter == null ? null : await _adapter.getBounds();

  Future<void> setBoundsForDiagnostics(Rect bounds) async {
    final adapter = _adapter;
    if (adapter == null) return;
    // A compositor can retain one maximized axis while reporting false here.
    // Clear both axes and let the native configure event precede the resize.
    await adapter.unmaximize();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await adapter.setBounds(bounds);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (DateTime.now().isBefore(deadline)) {
      final applied = await adapter.getBounds();
      if ((applied.left - bounds.left).abs() <= 1 &&
          (applied.top - bounds.top).abs() <= 1 &&
          (applied.width - bounds.width).abs() <= 1 &&
          (applied.height - bounds.height).abs() <= 1) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    await _persistCurrentState(reason: 'diagnostic_bounds');
  }

  @override
  void onWindowMoved() => _schedulePersist();

  @override
  void onWindowResized() => _schedulePersist();

  @override
  void onWindowClose() {
    if (_isClosing) return;
    _isClosing = true;
    _persistDebounce?.cancel();
    unawaited(_persistThenClose());
  }

  Future<void> _persistThenClose() async {
    final adapter = _adapter;
    if (adapter == null) return;
    await _persistCurrentState(reason: 'close');
    await adapter.setPreventClose(false);
    await adapter.close();
  }

  @override
  void onScreenEvent(String eventName) {
    unawaited(_reconcileCurrentDisplay(eventName));
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    _viewportDebounce?.cancel();
    if (_desktopRuntime) {
      _adapter?.removeListener(this);
      _screenAdapter?.removeListener(this);
    }
    super.dispose();
  }

  Future<void> _enterMiniPlayerMode() async {
    final adapter = _adapter!;
    final current = await adapter.getBounds();
    final maximized = await adapter.isMaximized();
    final previousNormalBounds = _stateRecord.normalBounds;
    final currentIsValidDesktop = supportsDesktopView(current.size);
    final nextNormalBounds = maximized && previousNormalBounds != null
        ? previousNormalBounds
        : currentIsValidDesktop
        ? DesktopWindowSnapshot(_normalizeDesktopBounds(current))
        : previousNormalBounds;
    _stateRecord = _stateRecord.copyWith(
      normalBounds: nextNormalBounds,
      normalWasMaximized: maximized,
      activeMode: DesktopWindowMode.miniPlayer,
    );
    if (maximized) await adapter.unmaximize();
    await _applyCommonWindowConstraints();
    await adapter.setAlwaysOnTop(miniAlwaysOnTop);
    final target = await _clampToVisibleWorkArea(
      _normalizeMiniBounds(_stateRecord.miniBounds?.bounds),
    );
    await adapter.setBounds(target);
    if (_stateRecord.miniBounds == null) await adapter.center();
    _stateRecord = _stateRecord.copyWith(
      miniBounds: DesktopWindowSnapshot(target),
    );
    _mode = DesktopWindowMode.miniPlayer;
    AppLogger.info('[DESKTOP_WINDOW] entered Mini Player');
  }

  Future<void> _exitMiniPlayerMode() async {
    final adapter = _adapter!;
    final current = await adapter.getBounds();
    _stateRecord = _stateRecord.copyWith(
      miniBounds: DesktopWindowSnapshot(_normalizeMiniBounds(current)),
      activeMode: DesktopWindowMode.desktop,
    );
    await _applyCommonWindowConstraints();
    await adapter.setAlwaysOnTop(false);
    final target = await _clampToVisibleWorkArea(
      _normalizeDesktopBounds(_stateRecord.normalBounds?.bounds),
    );
    await adapter.setBounds(target);
    if (_stateRecord.normalWasMaximized) await adapter.maximize();
    _mode = DesktopWindowMode.desktop;
    AppLogger.info('[DESKTOP_WINDOW] restored Desktop View');
  }

  Future<void> _restoreBoundsForCurrentMode() async {
    final adapter = _adapter;
    if (adapter == null) return;
    final target = await _clampToVisibleWorkArea(
      _mode == DesktopWindowMode.desktop
          ? _normalizeDesktopBounds(_stateRecord.normalBounds?.bounds)
          : _normalizeMiniBounds(_stateRecord.miniBounds?.bounds),
    );
    await adapter.setBounds(target);
  }

  Future<void> _applyCommonWindowConstraints() async {
    final adapter = _adapter!;
    await adapter.setResizable(true);
    await adapter.setAspectRatio(0);
    await adapter.setMaximumSize(const Size(-1, -1));
    await adapter.setMinimumSize(normalMinSize);
  }

  void _schedulePersist() {
    if (!_desktopRuntime || _adapter == null || _isApplyingMode) return;
    _persistDebounce?.cancel();
    _persistDebounce = Timer(_persistDebounceInterval, () {
      unawaited(_persistCurrentState(reason: 'debounced'));
    });
  }

  Future<void> _persistCurrentState({required String reason}) async {
    final adapter = _adapter;
    if (!_desktopRuntime || adapter == null || _stateFile.path.isEmpty) return;
    try {
      final current = await adapter.getBounds();
      final maximized = await adapter.isMaximized();
      if (_mode == DesktopWindowMode.miniPlayer) {
        if (supportsMiniPlayer(current.size)) {
          _stateRecord = _stateRecord.copyWith(
            miniBounds: DesktopWindowSnapshot(_normalizeMiniBounds(current)),
            activeMode: _mode,
            miniAlwaysOnTop: _miniAlwaysOnTop,
          );
        }
      } else if (supportsDesktopView(current.size) && !maximized) {
        _stateRecord = _stateRecord.copyWith(
          normalBounds: DesktopWindowSnapshot(_normalizeDesktopBounds(current)),
          normalWasMaximized: maximized,
          activeMode: _mode,
        );
      } else {
        _stateRecord = _stateRecord.copyWith(
          normalWasMaximized: maximized,
          activeMode: _mode,
        );
      }
      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(jsonEncode(_stateRecord.toJson()));
      _lastPersistenceCompleted = true;
      AppLogger.debug(
        '[DESKTOP_WINDOW] persisted mode=${_mode.name} reason=$reason',
      );
    } on Object catch (error, stackTrace) {
      _lastPersistenceCompleted = false;
      AppLogger.warning(
        'Failed to persist desktop window state. $error\n$stackTrace',
      );
    }
  }

  Future<DesktopWindowStateRecord> _readStateRecord() async {
    if (_stateFile.path.isEmpty || !await _stateFile.exists()) {
      return const DesktopWindowStateRecord.defaults();
    }
    try {
      return DesktopWindowStateRecord.fromJson(
        jsonDecode(await _stateFile.readAsString()),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to parse desktop window state. $error\n$stackTrace',
      );
      return const DesktopWindowStateRecord.defaults();
    }
  }

  Rect _normalizeDesktopBounds(Rect? bounds) {
    final source = bounds ?? const Rect.fromLTWH(0, 0, 1200, 760);
    return Rect.fromLTWH(
      source.left,
      source.top,
      source.width < kDesktopViewMinimumSize.width
          ? kDesktopViewMinimumSize.width
          : source.width,
      source.height < kDesktopViewMinimumSize.height
          ? kDesktopViewMinimumSize.height
          : source.height,
    );
  }

  Rect _normalizeMiniBounds(Rect? bounds) {
    final source =
        bounds ??
        Rect.fromLTWH(0, 0, miniDefaultSize.width, miniDefaultSize.height);
    return Rect.fromLTWH(
      source.left,
      source.top,
      miniDefaultSize.width,
      miniDefaultSize.height,
    );
  }

  static bool get _isWaylandSession {
    final sessionType = (Platform.environment['XDG_SESSION_TYPE'] ?? '')
        .toLowerCase();
    return sessionType == 'wayland' ||
        (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
  }

  Future<Rect> _clampToVisibleWorkArea(Rect bounds) async {
    final displays =
        await _screenAdapter?.getAllDisplays() ?? const <Display>[];
    if (displays.isEmpty) return bounds;
    var selected = displays.first;
    var bestIntersection = -1.0;
    for (final display in displays) {
      final area = _displayWorkArea(display);
      final intersection = bounds.intersect(area);
      final score = intersection.isEmpty
          ? 0.0
          : intersection.width * intersection.height;
      if (score > bestIntersection) {
        selected = display;
        bestIntersection = score;
      }
    }
    final area = _displayWorkArea(selected);
    _currentWorkArea = area;
    final width = bounds.width.clamp(
      1.0,
      area.width < bounds.width ? bounds.width : area.width,
    );
    final height = bounds.height.clamp(
      1.0,
      area.height < bounds.height ? bounds.height : area.height,
    );
    final maxLeft = area.right - width;
    final maxTop = area.bottom - height;
    return Rect.fromLTWH(
      bounds.left.clamp(area.left, maxLeft < area.left ? area.left : maxLeft),
      bounds.top.clamp(area.top, maxTop < area.top ? area.top : maxTop),
      width,
      height,
    );
  }

  Rect _displayWorkArea(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return position & size;
  }

  Future<void> _reconcileCurrentDisplay(String eventName) async {
    final adapter = _adapter;
    if (adapter == null || _isApplyingMode) return;
    try {
      final current = await adapter.getBounds();
      final clamped = await _clampToVisibleWorkArea(current);
      if (clamped != current) await adapter.setBounds(clamped);
      notifyListeners();
      AppLogger.debug('[DESKTOP_WINDOW] reconciled display event=$eventName');
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to reconcile desktop displays. $error\n$stackTrace',
      );
    }
  }
}

final desktopWindowControllerProvider =
    ChangeNotifierProvider<DesktopWindowController>((ref) {
      return DesktopWindowController.fallback(
        desktopRuntime: ref.watch(desktopPresentationRuntimeProvider),
      );
    });

/// Injectable runtime capability used by presentation tests to exercise the
/// non-desktop adaptive contracts while the test runner itself is on Linux.
final desktopPresentationRuntimeProvider = Provider<bool>(
  (_) => isDesktopRuntime,
);

final desktopWindowModeProvider = Provider<DesktopWindowMode>((ref) {
  return ref.watch(
    desktopWindowControllerProvider.select((controller) => controller.mode),
  );
});
