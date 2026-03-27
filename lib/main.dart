import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _unlockMobileOrientations();

  _initializeDesktopAudioBackend();
  final desktopBootstrap = await _configureDesktopWindow();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  AppLogger.info('Edge-to-edge mode enabled.');

  await NotificationBootstrap.initialize();

  runApp(
    ProviderScope(
      overrides: [
        if (desktopBootstrap != null)
          navisDatabaseProvider.overrideWith((ref) => desktopBootstrap.database),
        if (desktopBootstrap != null)
          settingsRepositoryProvider.overrideWith(
            (ref) => desktopBootstrap.settingsRepository,
          ),
        if (desktopBootstrap != null)
          desktopWindowControllerProvider.overrideWith(
            (ref) => desktopBootstrap.controller,
          ),
      ],
      child: const NavisApp(requirePlaybackBootstrap: true),
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

Future<_DesktopBootstrap?> _configureDesktopWindow() async {
  if (!_isDesktopRuntime) {
    return null;
  }

  try {
    final database = NavisDatabase();
    final settingsRepository = SettingsRepository(database.appSettingsDao);
    final controller = await DesktopWindowController.bootstrap(
      desktopRuntime: _isDesktopRuntime,
      settingsRepository: settingsRepository,
    );
    if (controller == null) {
      return null;
    }
    AppLogger.info('Desktop window manager initialized.');
    return _DesktopBootstrap(
      database: database,
      settingsRepository: settingsRepository,
      controller: controller,
    );
  } on Object catch (error, stackTrace) {
    AppLogger.warning(
      'Desktop window manager initialization failed. '
      'Continuing with default window behavior. '
      '$error\n$stackTrace',
    );
    return null;
  }
}

class _DesktopBootstrap {
  const _DesktopBootstrap({
    required this.database,
    required this.settingsRepository,
    required this.controller,
  });

  final NavisDatabase database;
  final SettingsRepository settingsRepository;
  final DesktopWindowController controller;
}

bool get _isDesktopRuntime =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get _isMobileRuntime => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

Future<void> _unlockMobileOrientations() async {
  if (!_isMobileRuntime) {
    return;
  }
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  AppLogger.info('Mobile orientation policy: all orientations enabled.');
}

const bool _forceEnableMediaKitInDebug = bool.fromEnvironment(
  'NAVIS_ENABLE_MEDIA_KIT_DEBUG',
  defaultValue: false,
);

bool get _shouldSkipDesktopMediaKitInitialization =>
    !_forceEnableMediaKitInDebug && kDebugMode && !kIsWeb && Platform.isMacOS;
