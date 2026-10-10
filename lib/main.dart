import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:navis/src/app.dart';
import 'package:navis/src/app_licenses.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/bootstrap/android_ui_bootstrap_gate.dart';
import 'package:navis/src/bootstrap/bundled_libmpv.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/android_background_sync_entrypoint.dart'
    as android_background_sync;
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/providers/provider_retry.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/android_diagnostics_startup.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/clone_diagnostics_path_provider.dart';
import 'package:navis/src/utils/credential_redaction.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/diagnostics_provider_counter.dart';
import 'package:navis/src/utils/notifications/notification_bootstrap.dart';
import 'package:navis/src/utils/sync_diagnostics_server.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Root-library entrypoint resolved by Android's headless FlutterEngine.
///
/// `DartExecutor.DartEntrypoint` resolves a named function from the app's root
/// library, so retaining the implementation only in a feature library is not
/// sufficient for profile or release builds even when it has its own pragma.
@pragma('vm:entry-point')
Future<void> navisBackgroundSyncEntrypoint() =>
    android_background_sync.navisBackgroundSyncEntrypoint();

// mpv's error lines, among other dependency output, quote full stream URLs
// whose token and salt are replayable credentials.
Future<void> main() => runWithCredentialRedactedPrint(_runNavis);

Future<void> _runNavis() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Errors nothing handled would otherwise be printed by the engine itself,
  // outside the redacting zone.
  PlatformDispatcher.instance.onError = reportUncaughtErrorRedacted;
  registerBundledLicenses();
  // Before anything resolves a directory: a desktop clone runs as the same OS
  // user as the real app, so its platform directories would be the real
  // profile's. (An Android sidecar is its own package with its own storage.)
  if (_syncDiagnosticsRequested &&
      _syncDiagnosticsMode == SyncDiagnosticsMode.clone &&
      _syncDiagnosticsRoot.isNotEmpty &&
      _isDesktopRuntime) {
    PathProviderPlatform.instance = CloneDiagnosticsPathProvider(
      root: _syncDiagnosticsRoot,
      platform: PathProviderPlatform.instance,
    );
  }

  _initializeDesktopAudioBackend();
  if (_isDesktopRuntime) {
    unawaited(UpdateService.cleanupStaledUpdates());
  }
  if (_syncDiagnosticsRuntimeEnabled &&
      _isAndroidRuntime &&
      _syncDiagnosticsMode == SyncDiagnosticsMode.clone) {
    final sidecar = await androidDiagnosticsIsSidecar();
    if (!sidecar) {
      throw StateError('Android clone diagnostics require a sidecar package.');
    }
    // Android must prepare its own scoped directory before Drift opens there.
    await androidDiagnosticsArtifactRoot();
  }
  try {
    await purgeLegacyCoverArtCredentials();
  } on FileSystemException catch (error) {
    // Retry next startup; the v2 manager never opens these legacy repositories.
    AppLogger.warning(
      'Legacy cover cache cleanup failed: ${error.runtimeType}.',
    );
  }
  final diagnosticsDatabase = _openDiagnosticsDatabase();
  if (diagnosticsDatabase != null && !_isAndroidRuntime) {
    // A desktop clone copies a real profile, whose download and cache rows
    // name the user's own files. Forget those before any service starts, so
    // nothing in the clone can move, rename or delete them. (An Android
    // sidecar's own cache lives outside its root and is not the user's.)
    final forgotten = await diagnosticsDatabase.cacheDao.forgetEntriesOutside(
      _syncDiagnosticsRoot,
    );
    if (forgotten > 0) {
      AppLogger.info(
        'Clone diagnostics: forgot $forgotten cached tracks outside the '
        'diagnostics root.',
      );
    }
  }
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
    // Planner statistics and the local-search index are refreshed off the
    // startup path. Both are derived data; a failure only costs speed.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 20), () async {
        try {
          await rootContainer
              .read(navisDatabaseProvider)
              .runDeferredMaintenance();
        } on Object catch (error) {
          AppLogger.debug('Deferred database maintenance skipped: $error');
        }
      }),
    );
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

final _diagnosticsProviderCounter = DiagnosticsProviderCounter();

ProviderContainer _createRootProviderContainer({
  required _DesktopBootstrap? desktopBootstrap,
  NavisDatabase? databaseOverride,
}) {
  var remainingInjectedBootstrapFailures =
      _diagnosticsAudioBootstrapFailureAttempts;
  return ProviderContainer(
    retry: navisProviderRetry,
    observers: [
      if (_syncDiagnosticsRuntimeEnabled) _diagnosticsProviderCounter,
    ],
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
      // Most sync diagnostics certify catalog scheduling and candidate
      // promotion, so they suppress the separate destructive cache-upgrade
      // route. Its focused clone scenario opts back in explicitly.
      if (_syncDiagnosticsRuntimeEnabled && !_allowCacheUpgradeDiagnostics)
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
    // libmpv up to 0.41 opens https streams without checking the server
    // certificate. The Linux and Windows LGPL bundles use the
    // system certificate store; macOS's bundled mpv 0.36 (Mbed TLS) is not
    // verified to find it yet, so it stays as before until that build is
    // replaced.
    JustAudioMediaKit.tlsVerify = Platform.isLinux || Platform.isWindows;
    // An isolated diagnostics run can capture its own native PCM without
    // changing the user's default output or routing other applications.
    const diagnosticsAudioDevice = String.fromEnvironment(
      'NAVIS_DIAGNOSTICS_AUDIO_DEVICE',
    );
    if (_syncDiagnosticsRuntimeEnabled &&
        _syncDiagnosticsMode == SyncDiagnosticsMode.clone &&
        diagnosticsAudioDevice.isNotEmpty) {
      JustAudioMediaKit.audioDevice = diagnosticsAudioDevice;
    }
    JustAudioMediaKit.ensureInitialized(
      linux: true,
      windows: true,
      macOS: true,
      libmpv: bundledLibmpvPath(),
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
    final isSidecar = await androidDiagnosticsIsSidecar();
    if (!isSidecar) {
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
    providerCounter: _diagnosticsProviderCounter,
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
  // surface. Keep artifacts in this package's scoped external files directory.
  if (_isAndroidRuntime &&
      _syncDiagnosticsMode == SyncDiagnosticsMode.primaryCertification) {
    final artifactRoot = await androidDiagnosticsArtifactRoot();
    return DiagnosticsPresentationController(artifactRoot: artifactRoot);
  }
  return null;
}

class _DesktopBootstrap {
  const new({
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
const bool _allowCacheUpgradeDiagnostics = bool.fromEnvironment(
  'NAVIS_SYNC_DIAGNOSTICS_ALLOW_CACHE_UPGRADE',
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
