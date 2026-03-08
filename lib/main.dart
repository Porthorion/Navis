import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _applyMobileOrientationPolicy();

  _initializeDesktopAudioBackend();
  await _configureDesktopWindow();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  AppLogger.info('Edge-to-edge mode enabled.');

  await NotificationBootstrap.initialize();

  runApp(
    const ProviderScope(
      child: NavisApp(requirePlaybackBootstrap: true),
    ),
  );
}

void _initializeDesktopAudioBackend() {
  if (!_isDesktopRuntime) {
    return;
  }

  if (_shouldSkipDesktopMediaKitInitialization) {
    AppLogger.info(
      'Desktop media_kit backend skipped in debug macOS mode to keep hot '
      'restart stable. Set --dart-define=NAVIS_ENABLE_MEDIA_KIT_DEBUG=true '
      'to force-enable it for this run.',
    );
    return;
  }

  try {
    JustAudioMediaKit.title = 'Navis';
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: true,
      macOS: true,
    );
    AppLogger.info('Desktop media_kit backend initialized.');
  } on Object catch (error, stackTrace) {
    AppLogger.warning(
      'Desktop media_kit backend initialization failed. '
      'Continuing with the default audio backend. '
      '$error\n$stackTrace',
    );
  }
}

Future<void> _configureDesktopWindow() async {
  if (!_isDesktopRuntime) {
    return;
  }

  try {
    final stateListener = await _DesktopWindowStateListener.create();
    _desktopWindowStateListener = stateListener;
    await windowManager.ensureInitialized();
    windowManager.addListener(stateListener);

    const minSize = Size(480, 600);
    final savedBounds = await stateListener.readSavedBounds();
    final startupBounds = _normalizeBounds(savedBounds, minSize: minSize);
    final options = WindowOptions(
      minimumSize: minSize,
      size: startupBounds?.size,
      center: startupBounds == null,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setMinimumSize(minSize);
      if (startupBounds != null) {
        await windowManager.setBounds(startupBounds);
      }
      await windowManager.show();
      await windowManager.focus();
    });
    AppLogger.info('Desktop window manager initialized.');
  } on Object catch (error, stackTrace) {
    AppLogger.warning(
      'Desktop window manager initialization failed. '
      'Continuing with default window behavior. '
      '$error\n$stackTrace',
    );
  }
}

// ignore: unused_element, reason: Retained to keep desktop window listener alive for the app lifecycle.
_DesktopWindowStateListener? _desktopWindowStateListener;

class _DesktopWindowStateListener with WindowListener {
  _DesktopWindowStateListener(this._stateFile);

  final File _stateFile;
  Timer? _persistDebounce;

  static const Duration _debounceInterval = Duration(milliseconds: 450);

  static Future<_DesktopWindowStateListener> create() async {
    final supportDir = await getApplicationSupportDirectory();
    final file = File(
      '${supportDir.path}${Platform.pathSeparator}window_state.json',
    );
    return _DesktopWindowStateListener(file);
  }

  Future<Rect?> readSavedBounds() async {
    if (!await _stateFile.exists()) {
      return null;
    }
    try {
      final raw = await _stateFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final x = (decoded['x'] as num?)?.toDouble();
      final y = (decoded['y'] as num?)?.toDouble();
      final width = (decoded['width'] as num?)?.toDouble();
      final height = (decoded['height'] as num?)?.toDouble();
      if (x == null || y == null || width == null || height == null) {
        return null;
      }
      if (width <= 0 || height <= 0) {
        return null;
      }
      return Rect.fromLTWH(x, y, width, height);
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to parse saved desktop window bounds. '
        '$error\n$stackTrace',
      );
      return null;
    }
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
    unawaited(_persistBounds());
  }

  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(_debounceInterval, () {
      unawaited(_persistBounds());
    });
  }

  Future<void> _persistBounds() async {
    try {
      final bounds = await windowManager.getBounds();
      await _stateFile.parent.create(recursive: true);
      await _stateFile.writeAsString(
        jsonEncode(<String, double>{
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        }),
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Failed to persist desktop window bounds. '
        '$error\n$stackTrace',
      );
    }
  }
}

Rect? _normalizeBounds(Rect? bounds, {required Size minSize}) {
  if (bounds == null) {
    return null;
  }
  final width = bounds.width < minSize.width ? minSize.width : bounds.width;
  final height = bounds.height < minSize.height
      ? minSize.height
      : bounds.height;
  return Rect.fromLTWH(bounds.left, bounds.top, width, height);
}

bool get _isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get _isMobileRuntime => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

Future<void> _applyMobileOrientationPolicy() async {
  if (!_isMobileRuntime) {
    return;
  }

  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) {
    return;
  }

  final view = views.first;
  final logicalSize = view.display.size / view.display.devicePixelRatio;
  final shortestSide = math.min(logicalSize.width, logicalSize.height);
  final longestSide = math.max(logicalSize.width, logicalSize.height);
  final isPhoneFormFactor = shortestSide < 600;

  if (!isPhoneFormFactor) {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    return;
  }

  // Keep startup orientation policy aligned with the in-app phone landscape
  // wide-mode rail gate used by AppShell.
  const shellDestinationCount = 4;
  const navTileEstimatedHeight = 64.0;
  const reservedMiniPlayerHeight = 170.0;
  const railMiniPlayerGap = 6.0;
  const railCutoffSlack = 4.0;
  const phoneRailOuterVerticalPadding = 44.0;
  const wideModeMinWidth = 840.0;

  final minPhoneRailHeight =
      (shellDestinationCount * navTileEstimatedHeight) +
      (reservedMiniPlayerHeight + railMiniPlayerGap) +
      railCutoffSlack;
  final landscapeEstimatedRailHeight =
      shortestSide - phoneRailOuterVerticalPadding;
  final supportsWideModeLandscape =
      longestSide >= wideModeMinWidth &&
      landscapeEstimatedRailHeight >= minPhoneRailHeight;

  if (supportsWideModeLandscape) {
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[]);
    AppLogger.info(
      'Mobile orientation policy: landscape allowed (wide-mode minimums met).',
    );
    return;
  }

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);
  AppLogger.info(
    'Mobile orientation policy: locked to portrait '
    '(wide-mode minimums not met).',
  );
}

const bool _forceEnableMediaKitInDebug = bool.fromEnvironment(
  'NAVIS_ENABLE_MEDIA_KIT_DEBUG',
  defaultValue: false,
);

bool get _shouldSkipDesktopMediaKitInitialization =>
    !_forceEnableMediaKitInDebug && kDebugMode && !kIsWeb && Platform.isMacOS;
