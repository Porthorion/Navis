import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as path;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _unlockMobileOrientations();

  _initializeDesktopAudioBackend();
  if (_isDesktopRuntime) {
    unawaited(UpdateService.cleanupStaledUpdates());
  }
  final diagnosticsDatabase = _openDiagnosticsDatabase();
  final desktopBootstrap = await _configureDesktopWindow(
    databaseOverride: diagnosticsDatabase,
  );
  final rootContainer = _createRootProviderContainer(
    desktopBootstrap: desktopBootstrap,
    databaseOverride: diagnosticsDatabase,
  );
  final diagnosticsPresentation = _createDiagnosticsPresentationController();
  rootContainer
      .read(audioBootstrapControllerProvider.notifier)
      .ensureInitialized();

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  AppLogger.info('Edge-to-edge mode enabled.');

  await NotificationBootstrap.initialize();

  final app = UncontrolledProviderScope(
    container: rootContainer,
    child: NavisApp(
      requirePlaybackBootstrap: true,
      schedulePlaybackBootstrap: false,
      onBootstrapOverlayDismissed: diagnosticsPresentation?.markAppReady,
    ),
  );
  runApp(diagnosticsPresentation?.wrap(app) ?? app);
  if (_syncDiagnosticsRuntimeEnabled) {
    unawaited(
      _startSyncDiagnostics(
        container: rootContainer,
        database: diagnosticsDatabase ?? desktopBootstrap?.database,
        presentationController: diagnosticsPresentation,
      ),
    );
  }
}

ProviderContainer _createRootProviderContainer({
  required _DesktopBootstrap? desktopBootstrap,
  NavisDatabase? databaseOverride,
}) {
  return ProviderContainer(
    overrides: [
      if (databaseOverride != null || desktopBootstrap != null)
        navisDatabaseProvider.overrideWith(
          (ref) => databaseOverride ?? desktopBootstrap!.database,
        ),
      if (desktopBootstrap != null)
        settingsRepositoryProvider.overrideWith(
          (ref) => desktopBootstrap.settingsRepository,
        ),
      if (desktopBootstrap != null)
        desktopWindowControllerProvider.overrideWith(
          (ref) => desktopBootstrap.controller,
        ),
    ],
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

Future<_DesktopBootstrap?> _configureDesktopWindow({
  NavisDatabase? databaseOverride,
}) async {
  if (!_isDesktopRuntime) {
    return null;
  }

  try {
    final database = databaseOverride ?? NavisDatabase();
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

NavisDatabase? _openDiagnosticsDatabase() {
  if (!_syncDiagnosticsRequested) {
    return null;
  }
  if (!_syncDiagnosticsRuntimeEnabled) {
    throw StateError(
      'Sync diagnostics require a Linux profile build and a valid mode.',
    );
  }
  if (_syncDiagnosticsMode == SyncDiagnosticsMode.primaryCertification) {
    if (_syncDiagnosticsDatabasePath.isNotEmpty) {
      throw StateError(
        'Primary certification must use the normal Navis database path.',
      );
    }
    return null;
  }
  if (_syncDiagnosticsRoot.isEmpty || _syncDiagnosticsDatabasePath.isEmpty) {
    throw StateError(
      'Clone diagnostics require an isolated root and database.',
    );
  }
  final root = path.normalize(path.absolute(_syncDiagnosticsRoot));
  final databasePath = path.normalize(
    path.absolute(_syncDiagnosticsDatabasePath),
  );
  if (!path.isWithin(root, databasePath)) {
    throw StateError('Diagnostics database must be inside the isolated root.');
  }
  return NavisDatabase.atPath(databasePath);
}

Future<void> _startSyncDiagnostics({
  required ProviderContainer container,
  required NavisDatabase? database,
  required DiagnosticsPresentationController? presentationController,
}) async {
  final mode = _syncDiagnosticsMode;
  if (mode == null || _syncDiagnosticsHandshakePath.isEmpty) {
    throw StateError('Sync diagnostics mode and handshake path are required.');
  }
  late final SyncDiagnosticsServer server;
  server = SyncDiagnosticsServer(
    container: container,
    mode: mode,
    handshakePath: _syncDiagnosticsHandshakePath,
    presentationController: presentationController,
    onShutdown: () async {
      await server.close();
      runApp(const SizedBox.shrink());
      await WidgetsBinding.instance.endOfFrame;
      container.dispose();
      await database?.close();
      exit(0);
    },
  );
  await server.start();
  AppLogger.info('Sync diagnostics API started in ${mode.name} mode.');
}

DiagnosticsPresentationController? _createDiagnosticsPresentationController() {
  if (!_syncDiagnosticsRuntimeEnabled ||
      _syncDiagnosticsMode != SyncDiagnosticsMode.clone) {
    return null;
  }
  return DiagnosticsPresentationController(
    artifactRoot: Directory(_syncDiagnosticsRoot),
  );
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

const bool _syncDiagnosticsRequested = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS',
  defaultValue: false,
);
const String _syncDiagnosticsModeValue = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_MODE',
);
const String _syncDiagnosticsRoot = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ROOT',
);
const String _syncDiagnosticsDatabasePath = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_DB_PATH',
);
const String _syncDiagnosticsHandshakePath = String.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE',
);

SyncDiagnosticsMode? get _syncDiagnosticsMode =>
    SyncDiagnosticsMode.parse(_syncDiagnosticsModeValue);

bool get _syncDiagnosticsRuntimeEnabled =>
    _syncDiagnosticsRequested &&
    kProfileMode &&
    !kIsWeb &&
    Platform.isLinux &&
    _syncDiagnosticsMode != null;

bool get _shouldSkipDesktopMediaKitInitialization =>
    !_forceEnableMediaKitInDebug && kDebugMode && !kIsWeb && Platform.isMacOS;
