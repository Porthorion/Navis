import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
