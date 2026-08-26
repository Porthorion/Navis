import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/bootstrap/android_ui_bootstrap_gate.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart'
    as android_background_sync;
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as path;

/// Root-library entrypoint resolved by Android's headless FlutterEngine.
///
/// [DartExecutor.DartEntrypoint] resolves a named function from the app's root
/// library, so retaining the implementation only in a feature library is not
/// sufficient for profile or release builds even when it has its own pragma.
@pragma('vm:entry-point')
Future<void> navisBackgroundSyncEntrypoint() =>
    android_background_sync.navisBackgroundSyncEntrypoint();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  final diagnosticsPresentation =
      await _createDiagnosticsPresentationController();
  rootContainer
      .read(audioBootstrapControllerProvider.notifier)
      .ensureInitialized();

  Future<void> startUi() async {
    await _unlockMobileOrientations();
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

  if (_isAndroidRuntime) {
    final gate = AndroidUiBootstrapGate(
      startUi: startUi,
      onError: (error, stackTrace) {
        AppLogger.error(
          'Android UI bootstrap failed. Media service remains available.',
          error,
          stackTrace,
        );
      },
    );
    _androidUiLifecycleListener?.dispose();
    _androidUiLifecycleListener = AppLifecycleListener(
      onResume: () {
        unawaited(gate.handleLifecycleState(AppLifecycleState.resumed));
      },
    );
    unawaited(
      gate.handleLifecycleState(WidgetsBinding.instance.lifecycleState),
    );
  } else {
    await startUi();
  }
}

AppLifecycleListener? _androidUiLifecycleListener;

ProviderContainer _createRootProviderContainer({
  required _DesktopBootstrap? desktopBootstrap,
  NavisDatabase? databaseOverride,
}) {
  var remainingInjectedBootstrapFailures =
      _diagnosticsAudioBootstrapFailureAttempts;
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
      // Sync diagnostics certify catalog scheduling and candidate promotion.
      // A cache-layout upgrade is a separate destructive recovery flow, so it
      // must not reset the disposable catalog while this runtime gate is
      // exercising interruption and restart recovery.
      if (_syncDiagnosticsRuntimeEnabled)
        cacheSystemUpgradeRequiredProvider.overrideWithValue(false),
      if (_isCloneBootstrapFailureDiagnostics)
        audioBootstrapAttemptGateProvider.overrideWithValue(() async {
          if (remainingInjectedBootstrapFailures <= 0) {
            return;
          }
          remainingInjectedBootstrapFailures -= 1;
          throw StateError('Injected audio bootstrap failure for diagnostics.');
        }),
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
      'Sync diagnostics require a supported profile build and a valid mode.',
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
  if (mode == null ||
      (!_isAndroidRuntime && _syncDiagnosticsHandshakePath.isEmpty)) {
    throw StateError('Sync diagnostics mode and handshake path are required.');
  }
  if (_isAndroidRuntime && mode == SyncDiagnosticsMode.clone) {
    final isSidecar = await _androidDiagnosticsHandshakeChannel
        .invokeMethod<bool>('isSidecar');
    if (isSidecar != true) {
      throw StateError(
        'Android clone diagnostics require a non-empty sidecar app-id suffix.',
      );
    }
  }
  late final SyncDiagnosticsServer server;
  server = SyncDiagnosticsServer(
    container: container,
    mode: mode,
    handshakePath: _isAndroidRuntime ? '' : _syncDiagnosticsHandshakePath,
    presentationController: presentationController,
    androidHandshakePublisher: _isAndroidRuntime
        ? _publishAndroidDiagnosticsHandshake
        : null,
    androidHandshakeClearer: _isAndroidRuntime
        ? _clearAndroidDiagnosticsHandshake
        : null,
    onShutdown: () async {
      await server.close();
      // A diagnostics shutdown must drain the startup/automatic sync before
      // closing Drift. Container disposal is synchronous, so without
      // this explicit barrier an in-flight planner can issue a final database
      // request after the isolate channel has already closed.
      await container
          .read(librarySyncControllerProvider.notifier)
          .cancelAndWait();
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

const MethodChannel _androidDiagnosticsHandshakeChannel = MethodChannel(
  'com.navis.app/diagnostics_handshake',
);

Future<void> _publishAndroidDiagnosticsHandshake(
  Map<String, Object?> handshake,
) async {
  await _androidDiagnosticsHandshakeChannel.invokeMethod<void>(
    'publish',
    handshake,
  );
}

Future<void> _clearAndroidDiagnosticsHandshake() =>
    _androidDiagnosticsHandshakeChannel.invokeMethod<void>('clear');

Future<DiagnosticsPresentationController?>
_createDiagnosticsPresentationController() async {
  if (!_syncDiagnosticsRuntimeEnabled) {
    return null;
  }
  if (_syncDiagnosticsMode == SyncDiagnosticsMode.clone) {
    return DiagnosticsPresentationController(
      artifactRoot: Directory(_syncDiagnosticsRoot),
    );
  }
  // Primary Android certification cannot mutate navigation or application
  // state, but app-owned screenshot capture is a required read-only evidence
  // surface. Keep artifacts in the sidecar's scoped external files directory.
  if (_isAndroidRuntime &&
      _syncDiagnosticsMode == SyncDiagnosticsMode.primaryCertification) {
    final artifactRoot = await _androidDiagnosticsHandshakeChannel
        .invokeMethod<String>('artifactRoot');
    if (artifactRoot == null || artifactRoot.isEmpty) {
      return null;
    }
    return DiagnosticsPresentationController(
      artifactRoot: Directory(artifactRoot),
    );
  }
  return null;
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

bool get _isAndroidRuntime => !kIsWeb && Platform.isAndroid;

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
const int _diagnosticsAudioBootstrapFailureAttempts = int.fromEnvironment(
  'NAVIS_DIAGNOSTICS_AUDIO_BOOTSTRAP_FAIL_ATTEMPTS',
  defaultValue: 0,
);

SyncDiagnosticsMode? get _syncDiagnosticsMode =>
    SyncDiagnosticsMode.parse(_syncDiagnosticsModeValue);

bool get _syncDiagnosticsRuntimeEnabled =>
    _syncDiagnosticsRequested &&
    kProfileMode &&
    !kIsWeb &&
    (Platform.isLinux || Platform.isWindows || Platform.isAndroid) &&
    _syncDiagnosticsMode != null;

bool get _isCloneBootstrapFailureDiagnostics =>
    _syncDiagnosticsRuntimeEnabled &&
    _syncDiagnosticsMode == SyncDiagnosticsMode.clone &&
    _diagnosticsAudioBootstrapFailureAttempts > 0;

bool get _shouldSkipDesktopMediaKitInitialization =>
    !_forceEnableMediaKitInDebug && kDebugMode && !kIsWeb && Platform.isMacOS;
