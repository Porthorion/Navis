import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

enum DesktopWindowMode { normal, focusPlayer }

@immutable
class DesktopWindowSnapshot {
  const DesktopWindowSnapshot(this.bounds);

  final Rect bounds;

  Map<String, double> toJson() {
    return <String, double>{
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    };
  }

  static DesktopWindowSnapshot? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    final width = (raw['width'] as num?)?.toDouble();
    final height = (raw['height'] as num?)?.toDouble();
    if (x == null || y == null || width == null || height == null) {
      return null;
    }
    if (width <= 0 || height <= 0) {
      return null;
    }
    return DesktopWindowSnapshot(Rect.fromLTWH(x, y, width, height));
  }
}

@immutable
class DesktopWindowStateRecord {
  const DesktopWindowStateRecord({
    required this.version,
    required this.activeMode,
    this.normalBounds,
    this.normalWasMaximized = false,
    this.focusBounds,
  });

  const DesktopWindowStateRecord.defaults()
    : version = currentVersion,
      activeMode = DesktopWindowMode.normal,
      normalBounds = null,
      normalWasMaximized = false,
      focusBounds = null;

  static const int currentVersion = 2;

  final int version;
  final DesktopWindowMode activeMode;
  final DesktopWindowSnapshot? normalBounds;
  final bool normalWasMaximized;
  final DesktopWindowSnapshot? focusBounds;

  DesktopWindowStateRecord copyWith({
    int? version,
    DesktopWindowMode? activeMode,
    DesktopWindowSnapshot? normalBounds,
    bool? normalWasMaximized,
    DesktopWindowSnapshot? focusBounds,
    bool clearNormalBounds = false,
    bool clearFocusBounds = false,
  }) {
    return DesktopWindowStateRecord(
      version: version ?? this.version,
      activeMode: activeMode ?? this.activeMode,
      normalBounds: clearNormalBounds
          ? null
          : normalBounds ?? this.normalBounds,
      normalWasMaximized: normalWasMaximized ?? this.normalWasMaximized,
      focusBounds: clearFocusBounds ? null : focusBounds ?? this.focusBounds,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': version,
      'activeMode': activeMode.name,
      'normalBounds': normalBounds?.toJson(),
      'normalWasMaximized': normalWasMaximized,
      'focusBounds': focusBounds?.toJson(),
    };
  }

  static DesktopWindowStateRecord fromJson(Object? raw) {
    if (raw is! Map) {
      return const DesktopWindowStateRecord.defaults();
    }

    // Migration path from the pre-focus single-bounds record.
    final legacySnapshot = DesktopWindowSnapshot.fromJson(raw);
    if (legacySnapshot != null && raw['version'] == null) {
      return DesktopWindowStateRecord(
        version: currentVersion,
        activeMode: DesktopWindowMode.normal,
        normalBounds: legacySnapshot,
        normalWasMaximized: false,
        focusBounds: null,
      );
    }

    final modeName = raw['activeMode'] as String?;
    final activeMode = DesktopWindowMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => DesktopWindowMode.normal,
    );
    return DesktopWindowStateRecord(
      version: (raw['version'] as num?)?.toInt() ?? currentVersion,
      activeMode: activeMode,
      normalBounds: DesktopWindowSnapshot.fromJson(raw['normalBounds']),
      normalWasMaximized: raw['normalWasMaximized'] as bool? ?? false,
      focusBounds: DesktopWindowSnapshot.fromJson(raw['focusBounds']),
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
  const WindowManagerDesktopWindowAdapter();

  @override
  Future<void> ensureInitialized() => windowManager.ensureInitialized();

  @override
  void addListener(WindowListener listener) => windowManager.addListener(listener);

  @override
  void removeListener(WindowListener listener) =>
      windowManager.removeListener(listener);

  @override
  Future<void> waitUntilReadyToShow(
    WindowOptions options,
    Future<void> Function() callback,
  ) {
    return windowManager.waitUntilReadyToShow(options, callback);
  }

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

class DesktopWindowController extends ChangeNotifier with WindowListener {
  DesktopWindowController({
    required bool desktopRuntime,
    required File stateFile,
    required SettingsRepository settingsRepository,
    WindowManagerAdapter? adapter,
  }) : _desktopRuntime = desktopRuntime,
       _stateFile = stateFile,
       _settingsRepository = settingsRepository,
       _adapter = adapter ?? const WindowManagerDesktopWindowAdapter();

  DesktopWindowController.fallback({bool desktopRuntime = false})
    : _desktopRuntime = desktopRuntime,
      _stateFile = File(''),
      _settingsRepository = null,
      _adapter = null;

  static const Size normalMinSize = Size(480, 600);
  static const Size focusDefaultSize = Size(960, 430);
  static const Size focusMinSize = Size(840, 376);
  static const Size focusMaxSize = Size(1040, 466);
  static const double focusAspectRatio = 960 / 430;
  static const Duration _persistDebounceInterval = Duration(milliseconds: 450);

  final bool _desktopRuntime;
  final File _stateFile;
  final SettingsRepository? _settingsRepository;
  final WindowManagerAdapter? _adapter;

  Timer? _persistDebounce;
  DesktopWindowMode _mode = DesktopWindowMode.normal;
  DesktopWindowStateRecord _stateRecord = const DesktopWindowStateRecord.defaults();
  bool _isInitialized = false;
  bool _isApplyingMode = false;

  bool get desktopRuntime => _desktopRuntime;
  bool get isInitialized => _isInitialized;
  bool get isApplyingMode => _isApplyingMode;
  DesktopWindowMode get mode => _mode;
  bool get isFocusPlayerMode => _mode == DesktopWindowMode.focusPlayer;

  static Future<DesktopWindowController?> bootstrap({
    required bool desktopRuntime,
    required SettingsRepository settingsRepository,
    WindowManagerAdapter? adapter,
  }) async {
    if (!desktopRuntime) {
      return null;
    }
    final supportDir = await getApplicationSupportDirectory();
    final stateFile = File(
      '${supportDir.path}${Platform.pathSeparator}window_state.json',
    );
    final controller = DesktopWindowController(
      desktopRuntime: desktopRuntime,
      stateFile: stateFile,
      settingsRepository: settingsRepository,
      adapter: adapter,
    );
    await controller.initialize();
    return controller;
  }

  Future<void> initialize() async {
    if (!_desktopRuntime || _isInitialized) {
      return;
    }
    final adapter = _adapter;
    final settingsRepository = _settingsRepository;
    if (adapter == null || settingsRepository == null) {
      _isInitialized = true;
      notifyListeners();
      return;
    }

    await adapter.ensureInitialized();
    adapter.addListener(this);
    _stateRecord = await _readStateRecord();
    final settings = await settingsRepository.getSettings();
    _mode = settings.desktopFocusPlayerModeEnabled
        ? DesktopWindowMode.focusPlayer
        : DesktopWindowMode.normal;
    _stateRecord = _stateRecord.copyWith(activeMode: _mode);
    final savedFocusBounds = _stateRecord.focusBounds?.bounds;

    final startupBounds = _mode == DesktopWindowMode.focusPlayer
        ? _resolveStartupFocusBounds(savedFocusBounds)
        : _normalizeNormalBounds(_stateRecord.normalBounds?.bounds);
    final options = WindowOptions(
      minimumSize: _mode == DesktopWindowMode.focusPlayer
          ? focusMinSize
          : normalMinSize,
      maximumSize: _mode == DesktopWindowMode.focusPlayer
          ? focusMaxSize
          : null,
      size: startupBounds?.size,
      center:
          startupBounds == null ||
          (_mode == DesktopWindowMode.focusPlayer && savedFocusBounds == null),
    );

    await adapter.waitUntilReadyToShow(options, () async {
      if (_mode == DesktopWindowMode.focusPlayer) {
        await _applyFocusWindowConstraints();
        if (startupBounds != null) {
          await adapter.setBounds(startupBounds);
          if (savedFocusBounds == null) {
            await adapter.center();
          }
        } else {
          await adapter.center();
        }
      } else {
        await _applyNormalWindowConstraints();
        if (startupBounds != null) {
          await adapter.setBounds(startupBounds);
        }
        if (_stateRecord.normalWasMaximized) {
          await adapter.maximize();
        }
      }
      await adapter.show();
      await adapter.focus();
    });

    _isInitialized = true;
    await _persistCurrentState(reason: 'initialize');
    notifyListeners();
    AppLogger.info(
      '[ACP_FOCUS] desktop window controller initialized mode=${_mode.name}',
    );
  }

  Future<void> setFocusPlayerMode(bool enabled) async {
    if (!_desktopRuntime) {
      return;
    }
    if (enabled == isFocusPlayerMode && _isInitialized) {
      return;
    }
    if (_adapter == null) {
      _mode = enabled ? DesktopWindowMode.focusPlayer : DesktopWindowMode.normal;
      notifyListeners();
      return;
    }
    if (_isApplyingMode) {
      return;
    }

    _isApplyingMode = true;
    notifyListeners();
    try {
      if (enabled) {
        await _enterFocusPlayerMode();
      } else {
        await _exitFocusPlayerMode();
      }
      await _saveFocusSetting(enabled);
      await _persistCurrentState(reason: enabled ? 'enter_focus' : 'exit_focus');
    } finally {
      _isApplyingMode = false;
      notifyListeners();
    }
  }

  Future<void> toggleFocusPlayerMode() {
    return setFocusPlayerMode(!isFocusPlayerMode);
  }

  @override
  void onWindowMoved() {
    _schedulePersist();
  }

  @override
  void onWindowResized() {
    _schedulePersist();
  }

  @override
  void onWindowClose() {
    _persistDebounce?.cancel();
    unawaited(_persistCurrentState(reason: 'close'));
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    final adapter = _adapter;
    if (adapter != null && _desktopRuntime) {
      adapter.removeListener(this);
    }
    super.dispose();
  }

  void _schedulePersist() {
    if (!_desktopRuntime || _adapter == null) {
      return;
    }
    _persistDebounce?.cancel();
    _persistDebounce = Timer(_persistDebounceInterval, () {
      unawaited(_persistCurrentState(reason: 'debounced'));
    });
  }

  Future<void> _enterFocusPlayerMode() async {
    final adapter = _adapter!;
    final currentBounds = await adapter.getBounds();
    final wasMaximized = await adapter.isMaximized();
    _stateRecord = _stateRecord.copyWith(
      normalBounds: DesktopWindowSnapshot(
        _normalizeNormalBounds(currentBounds) ?? currentBounds,
      ),
      normalWasMaximized: wasMaximized,
      activeMode: DesktopWindowMode.focusPlayer,
    );

    if (wasMaximized) {
      await adapter.unmaximize();
    }
    await _applyFocusWindowConstraints();
    final savedFocusBounds = _stateRecord.focusBounds?.bounds;
    final targetBounds = _resolveStartupFocusBounds(savedFocusBounds);
    await adapter.setBounds(targetBounds);
    if (savedFocusBounds == null) {
      await adapter.center();
    }
    _mode = DesktopWindowMode.focusPlayer;
    AppLogger.info('[ACP_FOCUS] entered focus player mode');
  }

  Future<void> _exitFocusPlayerMode() async {
    final adapter = _adapter!;
    final currentBounds = await adapter.getBounds();
    _stateRecord = _stateRecord.copyWith(
      focusBounds: DesktopWindowSnapshot(_clampFocusBounds(currentBounds)),
      activeMode: DesktopWindowMode.normal,
    );
    await _applyNormalWindowConstraints();
    final restoreBounds = _normalizeNormalBounds(_stateRecord.normalBounds?.bounds);
    if (restoreBounds != null) {
      await adapter.setBounds(restoreBounds);
    }
    if (_stateRecord.normalWasMaximized) {
      await adapter.maximize();
    }
    _mode = DesktopWindowMode.normal;
    AppLogger.info('[ACP_FOCUS] restored normal desktop window');
  }

  Future<void> _applyFocusWindowConstraints() async {
    final adapter = _adapter!;
    await adapter.setResizable(true);
    await adapter.setMinimumSize(focusMinSize);
    await adapter.setMaximumSize(focusMaxSize);
    await adapter.setAspectRatio(focusAspectRatio);
  }

  Future<void> _applyNormalWindowConstraints() async {
    final adapter = _adapter!;
    await adapter.setResizable(true);
    await adapter.setAspectRatio(0);
    await adapter.setMaximumSize(const Size(-1, -1));
    await adapter.setMinimumSize(normalMinSize);
  }

  Future<void> _saveFocusSetting(bool enabled) async {
    final repository = _settingsRepository;
    if (repository == null) {
      return;
    }
    final current = await repository.getSettings();
    await repository.saveSettings(
      current.copyWith(desktopFocusPlayerModeEnabled: enabled),
    );
  }

  Future<DesktopWindowStateRecord> _readStateRecord() async {
    if (_stateFile.path.isEmpty || !await _stateFile.exists()) {
      return const DesktopWindowStateRecord.defaults();
    }
    try {
      final raw = await _stateFile.readAsString();
      return DesktopWindowStateRecord.fromJson(jsonDecode(raw));
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to parse desktop window state. $error\n$stackTrace',
      );
      return const DesktopWindowStateRecord.defaults();
    }
  }

  Future<void> _persistCurrentState({required String reason}) async {
    final adapter = _adapter;
    if (!_desktopRuntime || adapter == null || _stateFile.path.isEmpty) {
      return;
    }
    try {
      final currentBounds = await adapter.getBounds();
      final maximized = await adapter.isMaximized();
      if (_mode == DesktopWindowMode.focusPlayer) {
        _stateRecord = _stateRecord.copyWith(
          focusBounds: DesktopWindowSnapshot(_clampFocusBounds(currentBounds)),
          activeMode: DesktopWindowMode.focusPlayer,
        );
      } else {
        _stateRecord = _stateRecord.copyWith(
          normalBounds: maximized
              ? _stateRecord.normalBounds
              : DesktopWindowSnapshot(
                  _normalizeNormalBounds(currentBounds) ?? currentBounds,
                ),
          normalWasMaximized: maximized,
          activeMode: DesktopWindowMode.normal,
        );
      }
      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(jsonEncode(_stateRecord.toJson()));
      AppLogger.debug(
        '[ACP_FOCUS] persisted desktop window state mode=${_mode.name} reason=$reason',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to persist desktop window state. $error\n$stackTrace',
      );
    }
  }

  Rect? _normalizeNormalBounds(Rect? bounds) {
    if (bounds == null) {
      return null;
    }
    final width = bounds.width < normalMinSize.width
        ? normalMinSize.width
        : bounds.width;
    final height = bounds.height < normalMinSize.height
        ? normalMinSize.height
        : bounds.height;
    return Rect.fromLTWH(bounds.left, bounds.top, width, height);
  }

  Rect _resolveStartupFocusBounds(Rect? bounds) {
    return _clampFocusBounds(
      bounds ?? Rect.fromLTWH(0, 0, focusDefaultSize.width, focusDefaultSize.height),
    );
  }

  Rect _clampFocusBounds(Rect bounds) {
    final clampedWidth = bounds.width.clamp(
      focusMinSize.width,
      focusMaxSize.width,
    );
    final heightFromWidth = clampedWidth / focusAspectRatio;
    final clampedHeight = heightFromWidth.clamp(
      focusMinSize.height,
      focusMaxSize.height,
    );
    final widthFromHeight = clampedHeight * focusAspectRatio;
    return Rect.fromLTWH(bounds.left, bounds.top, widthFromHeight, clampedHeight);
  }
}

final desktopWindowControllerProvider =
    ChangeNotifierProvider<DesktopWindowController>((ref) {
      return DesktopWindowController.fallback(desktopRuntime: isDesktopRuntime);
    });

final desktopWindowModeProvider = Provider<DesktopWindowMode>((ref) {
  return ref.watch(
    desktopWindowControllerProvider.select((controller) => controller.mode),
  );
});
