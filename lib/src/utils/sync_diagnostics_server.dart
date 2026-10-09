import 'package:navis/src/features/downloads/presentation/custom_download_folder_controller.dart';
import 'package:navis/src/features/downloads/presentation/manual_download_matching_provider.dart';
import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/equalizer/data/eq_import_parser.dart';
import 'package:navis/src/features/equalizer/presentation/eq_controller.dart';
import 'package:navis/src/features/player/presentation/playback_adjustment_controller.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart'
    show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:drift/drift.dart' show TableUpdate;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/common_widgets/app_notice.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/features/settings/domain/navis_density.dart';
import 'package:navis/src/features/settings/domain/now_playing_background.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/downloads/data/permanent_download_import_service.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:path/path.dart' as p;
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild.dart';
import 'package:navis/src/features/library/presentation/required_library_rebuild_provider.dart';
import 'package:navis/src/features/library/presentation/artist_playback_controller.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/home/presentation/home_onboarding_warmup.dart';
import 'package:navis/src/features/onboarding/presentation/onboarding_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/player/presentation/personal_radio_notifier.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/playback_recovery_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/desktop_commands.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/theme/navis_corner_style.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/diagnostics_provider_counter.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:navis/src/routing/app_routes.dart';
import 'package:navis/src/routing/navigation_service.dart';
import 'package:navis/src/routing/navigation_history_provider.dart';

enum SyncDiagnosticsMode {
  clone,
  primaryCertification;

  static SyncDiagnosticsMode? parse(String value) => switch (value) {
    'clone' => clone,
    'primary-certification' => primaryCertification,
    _ => null,
  };
}

class SyncDiagnosticsServer {
  new({
    required ProviderContainer container,
    required this.mode,
    required this.handshakePath,
    required this.onShutdown,
    this.presentationController,
    this.providerCounter,
    this.androidHandshakePublisher,
    this.androidHandshakeClearer,
    DiagnosticsNavigationDriver? navigationDriver,
    Random? random,
  }) : _container = container,
       _navigationDriver =
           navigationDriver ??
           ProviderDiagnosticsNavigationDriver(
             () => container.read(appRouterProvider),
           ),
       _random = random ?? Random.secure();

  final ProviderContainer _container;
  final SyncDiagnosticsMode mode;
  final String handshakePath;
  final Future<void> Function() onShutdown;
  final DiagnosticsPresentationController? presentationController;
  final DiagnosticsProviderCounter? providerCounter;
  final Future<void> Function(Map<String, Object?> handshake)?
  androidHandshakePublisher;
  final Future<void> Function()? androidHandshakeClearer;
  final DiagnosticsNavigationDriver _navigationDriver;
  final Random _random;
  final List<int> _frameMicros = <int>[];
  final List<int> _frameBuildMicros = <int>[];
  final List<int> _frameRasterMicros = <int>[];
  final List<int> _frameSpanMicros = <int>[];
  final List<Map<String, Object?>> _slowFrameSamples = <Map<String, Object?>>[];
  DateTime _frameWindowStartedAt = DateTime.now();
  int _frameWindowCount = 0;
  // Heartbeat: a ticker that requests every frame, recording the wall-clock
  // gap between frames, plus a short timer measuring event-loop lag. A blocked
  // UI or (merged) platform thread produces no frames at all, so frame timings
  // alone cannot show a freeze; these gaps can.
  bool _heartbeatEnabled = false;
  bool _heartbeatCallbackRegistered = false;
  Timer? _heartbeatLagTimer;
  final Stopwatch _heartbeatWatch = Stopwatch();
  int _heartbeatLastTickMicros = 0;
  int _heartbeatLastLagMicros = 0;
  final List<int> _heartbeatGapMicros = <int>[];
  final List<int> _eventLoopLagMicros = <int>[];
  Map<String, Object?> _playbackCounterBaseline = const <String, Object?>{};
  // Drift table-update notifications per table since the last metrics reset;
  // each one re-runs every live query that reads the table.
  final Map<String, int> _tableUpdateCounts = <String, int>{};
  StreamSubscription<Set<TableUpdate>>? _tableUpdateSubscription;
  final List<int> _databaseCanaryMicros = <int>[];
  final Map<String, List<int>> _databaseCanaryMicrosByPhase =
      <String, List<int>>{};
  final List<Map<String, Object?>> _slowDatabaseCanarySamples =
      <Map<String, Object?>>[];
  final DateTime _startedAt = DateTime.now();
  late final String _token;
  HttpServer? _server;
  Timer? _canaryTimer;
  bool _canaryRunning = false;
  Future<LibrarySyncState>? _activeSync;
  LibrarySyncState? _lastSync;
  Object? _lastSyncError;
  final List<Map<String, Object?>> _syncLedger = <Map<String, Object?>>[];
  int _nextSyncLedgerId = 1;
  Map<String, Song> _presentationSearchSongs = const <String, Song>{};
  StreamSubscription<Object?>? _playbackFailureSubscription;
  ProviderSubscription<InitialServerSyncState>? _initialSyncSubscription;
  int _playbackFailureCount = 0;

  bool get allowsMutations => mode == SyncDiagnosticsMode.clone;

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _token = base64Url
        .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
        .replaceAll('=', '');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
    _canaryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_runDatabaseCanary()),
    );
    _tableUpdateSubscription = _container
        .read(navisDatabaseProvider)
        .tableUpdates()
        .listen((updates) {
          for (final update in updates) {
            _tableUpdateCounts.update(
              update.table,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
          }
        });
    final handler = _container.read(audioHandlerProvider);
    _playbackFailureSubscription = handler?.loadFailureStream.listen((_) {
      _playbackFailureCount++;
    });
    try {
      await _writeHandshake(server.port);
    } on Object {
      await close();
      rethrow;
    }
    unawaited(_serve(server));
  }

  Future<void> close() async {
    final server = _server;
    if (server == null) {
      return;
    }
    _server = null;
    _canaryTimer?.cancel();
    _canaryTimer = null;
    _stopHeartbeat();
    await _tableUpdateSubscription?.cancel();
    _tableUpdateSubscription = null;
    SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
    await _playbackFailureSubscription?.cancel();
    _playbackFailureSubscription = null;
    _initialSyncSubscription?.close();
    _initialSyncSubscription = null;
    await server.close(force: true);
    final clearer = androidHandshakeClearer;
    if (clearer != null) {
      await clearer();
    } else {
      final file = File(handshakePath);
      // Keep metadata access asynchronous so storage latency cannot stall UI.
      // ignore: avoid_slow_async_io
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
  }

  Map<String, Object?> _mixStatusJson() {
    final session = _container.read(recommendationSessionProvider);
    final radio = _container.read(personalRadioProvider);
    final server = _container.read(instantMixProvider);
    final lastFm = _container.read(sameVibesProvider);
    return <String, Object?>{
      'appVersion': _container.read(packageInfoProvider).asData?.value.version,
      'selectedSongMix':
          _container.read(preferredMixModeProvider) ==
              PreferredMixMode.legacyInstantMix
          ? 'server'
          : 'lastfm',
      'mode': session.mode?.name,
      'operationId': session.generation,
      'seedId': session.seedId,
      'stage': session.stage,
      'recommendationSource': session.source,
      'candidateCount': session.candidateCount,
      'insertedCount': session.insertedCount,
      'errorCategory': session.errorCategory,
      'retryCount': session.retryCount,
      'retryState': session.stage == 'retryPending'
          ? 'pending'
          : session.stage == 'retryExhausted'
          ? 'exhausted'
          : 'none',
      'active': radio.active || server.active || lastFm.active,
    };
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          'Bearer $_token') {
        await _respond(request, HttpStatus.unauthorized, <String, Object?>{
          'error': 'unauthorized',
        });
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/health') {
        final counts = await _container
            .read(navisDatabaseProvider)
            .libraryDao
            .getCatalogCounts();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'status': 'ok',
          'mode': mode.name,
          'schemaVersion': _container.read(navisDatabaseProvider).schemaVersion,
          'catalog': <String, int>{
            'artists': counts.artists,
            'albums': counts.albums,
            'songs': counts.songs,
          },
        });
        return;
      }
      if (path == '/v1/mix/status' && request.method == 'GET') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _respond(request, HttpStatus.ok, _mixStatusJson());
        return;
      }
      if (path == '/v1/mix/start' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final rawMode = body['mode'];
        final mode = rawMode == 'selected'
            ? (_container.read(preferredMixModeProvider) ==
                      PreferredMixMode.legacyInstantMix
                  ? 'server'
                  : 'lastfm')
            : rawMode;
        if (mode != 'server' && mode != 'lastfm' && mode != 'radio') {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'mode must be selected, server, lastfm, or radio',
          });
          return;
        }
        await _waitForPlaybackHandler();
        if (mode == 'radio') {
          final likedOnly = body['likedOnly'];
          final downloadedOnly = body['downloadedOnly'];
          if ((likedOnly != null && likedOnly is! bool) ||
              (downloadedOnly != null && downloadedOnly is! bool)) {
            await _respond(request, HttpStatus.badRequest, <String, Object?>{
              'error': 'radio filters must be booleans',
            });
            return;
          }
          final result = await _container
              .read(personalRadioProvider.notifier)
              .start(
                filters: RadioFilters(
                  likedOnly: likedOnly == true,
                  downloadedOnly: downloadedOnly == true,
                ),
              );
          await _respond(
            request,
            result.succeeded ? HttpStatus.ok : HttpStatus.unprocessableEntity,
            _mixStatusJson(),
          );
          return;
        }
        final seedId = body['seedId'];
        if (seedId is! String || seedId.trim().isEmpty) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'seedId is required for song mixes',
          });
          return;
        }
        if (mode == 'server') {
          await _container.read(instantMixProvider.notifier).activate(seedId);
        } else {
          await _container.read(sameVibesProvider.notifier).activate(seedId);
        }
        final status = _container.read(recommendationSessionProvider);
        await _respond(
          request,
          status.insertedCount > 0
              ? HttpStatus.ok
              : HttpStatus.unprocessableEntity,
          _mixStatusJson(),
        );
        return;
      }
      if (path == '/v1/mix/stop' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        _container.read(instantMixProvider.notifier).deactivate();
        _container.read(sameVibesProvider.notifier).deactivate();
        _container.read(personalRadioProvider.notifier).stop();
        await _respond(request, HttpStatus.ok, _mixStatusJson());
        return;
      }
      if (path == '/v1/mix/retry' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final status = _container.read(recommendationSessionProvider);
        final seedId = status.seedId;
        switch (status.mode) {
          case RecommendationMode.serverMix when seedId != null:
            await _container.read(instantMixProvider.notifier).activate(seedId);
          case RecommendationMode.sameVibes when seedId != null:
            await _container.read(sameVibesProvider.notifier).activate(seedId);
          case RecommendationMode.personalRadio:
            await _container.read(personalRadioProvider.notifier).retry();
          case _:
            await _respond(request, HttpStatus.conflict, <String, Object?>{
              'error': 'no recommendation session to retry',
            });
            return;
        }
        final result = _mixStatusJson();
        await _respond(
          request,
          (result['insertedCount'] as int? ?? 0) > 0
              ? HttpStatus.ok
              : HttpStatus.unprocessableEntity,
          result,
        );
        return;
      }
      if (request.method == 'GET' && path == '/v1/presentation/window') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _respond(request, HttpStatus.ok, await _windowPresentationJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/window') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final controller = _container.read(desktopWindowControllerProvider);
        final mode = body['mode'];
        final resolution = body['transitionResolution'];
        final alwaysOnTop = body['miniAlwaysOnTop'];
        final width = (body['width'] as num?)?.toDouble();
        final height = (body['height'] as num?)?.toDouble();
        if (mode != null && mode != 'desktop' && mode != 'miniPlayer') {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'mode must be desktop or miniPlayer',
          });
          return;
        }
        if (resolution != null &&
            resolution != 'switchMode' &&
            resolution != 'restoreBounds') {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'transitionResolution must be switchMode or restoreBounds',
          });
          return;
        }
        if (alwaysOnTop != null && alwaysOnTop is! bool) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'miniAlwaysOnTop must be a boolean',
          });
          return;
        }
        if ((width == null) != (height == null) ||
            (width != null && !supportsMiniPlayer(Size(width, height!)))) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'width and height must be at least 560 by 360',
          });
          return;
        }
        if (width != null && height != null) {
          final current =
              await controller.getCurrentBounds() ??
              Rect.fromLTWH(0, 0, width, height);
          await controller.setBoundsForDiagnostics(
            Rect.fromLTWH(current.left, current.top, width, height),
          );
          controller.updateViewportSize(Size(width, height));
          await Future<void>.delayed(
            DesktopWindowController.resizeSettleInterval +
                const Duration(milliseconds: 20),
          );
        }
        if (mode != null) {
          await controller.setMiniPlayerMode(mode == 'miniPlayer');
        }
        if (alwaysOnTop case final bool enabled) {
          await controller.setMiniAlwaysOnTop(enabled);
        }
        if (resolution != null) {
          await controller.resolveTransition(
            switchMode: resolution == 'switchMode',
          );
        }
        await presentationController?.waitForFrame();
        await _respond(request, HttpStatus.ok, await _windowPresentationJson());
        return;
      }
      if (request.method == 'GET' && path == '/v1/presentation/status') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'route': _navigationDriver.location,
          'appReady': presentation.appReady,
          ...presentation.status.toJson(),
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/dismiss-popup') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await presentation.dismissPopupRoutes();
        await _respond(request, HttpStatus.ok, {'status': 'dismissed'});
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/navigate') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final rawLocation = body['location'];
        final location = rawLocation is String ? rawLocation.trim() : '';
        if (!_isValidDiagnosticsLocation(location)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'location must be a local absolute route',
          });
          return;
        }
        if (!_navigationDriver.resolves(location)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'location does not match an app route',
          });
          return;
        }
        final librarySection = _librarySectionForDiagnosticsLocation(location);
        _navigationDriver.go(
          librarySection == null
              ? location
              : AppRoutes.librarySection(librarySection.name),
        );
        if (librarySection != null) {
          _container
              .read(librarySectionProvider.notifier)
              .setSection(librarySection);
        }
        await presentation.waitForFrame();
        final actualLocation = _navigationDriver.location;
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'requestedLocation': location,
          'actualLocation': actualLocation,
          'redirected': actualLocation != location,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/setup-highlights/reset') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final database = _container.read(navisDatabaseProvider);
        await database.transaction(() async {
          await database.appSettingsDao.clearSetupHighlightsSeen();
          await database.appSettingsDao.updateSetupHighlightsSeenRelease(null);
          await database.appSettingsDao.updateSetupCardDismissedRelease(null);
        });
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'setupHighlightsSeen': <String>[],
          'setupHighlightsSeenRelease': null,
          'setupCardDismissedRelease': null,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/onboarding/complete') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await _container.read(onboardingCompletionServiceProvider).complete();
        await presentation.waitForFrame();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'actualLocation': _navigationDriver.location,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/onboarding/step') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final step = body['step'];
        if (body.length != 1 || step is! int) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'send {"step": <0-based integer>}',
          });
          return;
        }
        try {
          final shown = await presentation.setOnboardingStep(step);
          await _respond(request, HttpStatus.ok, <String, Object?>{
            'step': shown,
          });
        } on DiagnosticsPresentationOutOfRange catch (range) {
          await _respond(request, HttpStatus.notFound, <String, Object?>{
            'error': 'step must be 0 to ${range.count - 1}',
          });
        } on DiagnosticsPresentationUnavailable {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'onboarding is not mounted',
          });
        }
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/onboarding/focus') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final field = body['field'];
        if (body.length != 1 ||
            field is! String ||
            (field != 'none' &&
                !DiagnosticsPresentationController.onboardingFocusFields
                    .containsKey(field))) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'field must be "listenBrainzToken", "lastFmKey" or "none"',
          });
          return;
        }
        try {
          final focused = await presentation.focusOnboardingField(field);
          await _respond(request, HttpStatus.ok, <String, Object?>{
            'field': field,
            'focused': focused,
          });
        } on DiagnosticsPresentationUnavailable {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'onboarding or that field is not shown',
          });
        }
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/release-card') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final rawSurface = body['surface'];
        final rawIndex = body['index'] ?? 0;
        final surface = rawSurface is String ? rawSurface : null;
        final index = rawIndex is int ? rawIndex : null;
        final isTap =
            surface != null &&
            DiagnosticsPresentationController.releaseSurfaces.containsKey(
              surface,
            ) &&
            index != null &&
            index >= 0 &&
            body.keys.every((key) => key == 'surface' || key == 'index');
        if (!isTap) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error':
                'send {"surface": "missingAlbums" | "newReleases", '
                '"index": <0-based integer>}',
          });
          return;
        }
        try {
          final result = await presentation.tapReleaseCard(
            surface: surface,
            index: index,
            location: () => _navigationDriver.location,
          );
          await _respond(request, HttpStatus.ok, result.toJson());
        } on DiagnosticsPresentationOutOfRange catch (range) {
          await _respond(request, HttpStatus.notFound, <String, Object?>{
            'error': 'the surface shows ${range.count} cards',
          });
        } on DiagnosticsPresentationUnavailable {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'that surface has no tappable card',
          });
        }
        return;
      }
      if (request.method == 'GET' && path == '/v1/presentation/home-warmup') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final status = _container
            .read(homeOnboardingWarmupTrackerProvider)
            .status;
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'targetCount': status.targetCount,
          'readyCount': status.readyCount,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/track-action') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        if (body.length != 1 ||
            action is! String ||
            !DiagnosticsPresentationController.trackActions.contains(action)) {
          throw const FormatException();
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await presentation.activateTrackControl(action: action);
        await _respond(request, HttpStatus.ok, {'action': action});
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/library-action') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        if (body.length != 1 ||
            action is! String ||
            !DiagnosticsPresentationController.libraryActions.contains(
              action,
            )) {
          throw const FormatException();
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await presentation.activateLibraryControl(action: action);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'action': action,
          'actualLocation': _navigationDriver.location,
        });
        return;
      }
      if ((request.method == 'GET' || request.method == 'POST') &&
          path == '/v1/presentation/appearance') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final dao = _container.read(navisDatabaseProvider).appSettingsDao;
        if (request.method == 'POST') {
          final body = await _readJson(request);
          final size = body['gridArtworkSize'];
          final autoAdvance = body['homeRecommendationsAutoAdvance'];
          final artists = body['showArtistsPage'];
          final radio = body['showRadioPage'];
          final coverShape = body['coverArtShape'];
          final nowPlayingShape = body['nowPlayingArtShape'];
          final artistShape = body['artistCardShape'];
          const shapes = ['square', 'rounded', 'circle'];
          if (body.keys.any(
                (key) => !const {
                  'gridArtworkSize',
                  'homeRecommendationsAutoAdvance',
                  'showArtistsPage',
                  'showRadioPage',
                  'coverArtShape',
                  'nowPlayingArtShape',
                  'artistCardShape',
                }.contains(key),
              ) ||
              (size != null &&
                  !const ['auto', 'small', 'medium', 'large'].contains(size)) ||
              (autoAdvance != null && autoAdvance is! bool) ||
              (artists != null && artists is! bool) ||
              (radio != null && radio is! bool) ||
              // Cover art offers only square and rounded, like Appearance.
              (coverShape != null &&
                  !const ['square', 'rounded'].contains(coverShape)) ||
              (nowPlayingShape != null && !shapes.contains(nowPlayingShape)) ||
              (artistShape != null && !shapes.contains(artistShape)) ||
              body.isEmpty) {
            throw const FormatException();
          }
          if (coverShape is String) await dao.updateCoverArtShape(coverShape);
          if (nowPlayingShape is String) {
            await dao.updateNowPlayingArtShape(nowPlayingShape);
          }
          if (artistShape is String) {
            await dao.updateArtistCardShape(artistShape);
          }
          if (size is String) await dao.updateGridArtworkSize(size);
          if (autoAdvance is bool) {
            await dao.updateHomeRecommendationsAutoAdvance(
              enabled: autoAdvance,
            );
          }
          if (artists is bool) {
            await dao.updateShowArtistsPage(enabled: artists);
          }
          if (radio is bool) await dao.updateShowRadioPage(enabled: radio);
          await presentationController?.waitForFrame();
        }
        final settings = await dao.getSettings();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'gridArtworkSize': settings?.gridArtworkSize ?? 'auto',
          'showArtistsPage': settings?.showArtistsPage ?? true,
          'showRadioPage': settings?.showRadioPage ?? true,
          'homeRecommendationsAutoAdvance':
              settings?.homeRecommendationsAutoAdvance ?? false,
          'coverArtShape': settings?.coverArtShape ?? 'square',
          'nowPlayingArtShape': settings?.nowPlayingArtShape ?? 'rounded',
          'nowPlayingBackground': NowPlayingBackground.parse(
            settings?.nowPlayingBackground,
          ).storageKey,
          'cornerStyle': NavisCornerStyle.parse(settings?.cornerStyle).name,
          'density': NavisDensity.parse(settings?.homeDensity).storageKey,
          'artistCardShape': settings?.artistCardShape ?? 'circle',
        });
        return;
      }
      if ((request.method == 'GET' || request.method == 'POST') &&
          path == '/v1/presentation/integrations') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final dao = _container.read(navisDatabaseProvider).appSettingsDao;
        if (request.method == 'POST') {
          final body = await _readJson(request);
          final master = body['master'];
          final key = body['key'];
          final enabled = body['enabled'];
          if (body.isEmpty ||
              body.keys.any(
                (name) => !const {'master', 'key', 'enabled'}.contains(name),
              ) ||
              (master != null && master is! bool) ||
              (key == null) != (enabled == null) ||
              (key != null && (key is! String || !isIntegrationKey(key))) ||
              (enabled != null && enabled is! bool)) {
            throw const FormatException();
          }
          if (master is bool) {
            await dao.setExternalIntegrationsEnabled(enabled: master);
          }
          if (key is String && enabled is bool) {
            await dao.setIntegrationEnabled(key, enabled: enabled);
          }
        }
        await _respond(request, HttpStatus.ok, await _integrationsSnapshot());
        return;
      }
      if ((request.method == 'GET' || request.method == 'POST') &&
          path == '/v1/presentation/playback-settings') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        if (request.method == 'POST') {
          final body = await _readJson(request);
          final toggle = body['toggle'];
          if (body.length != 1 ||
              toggle is! String ||
              !DiagnosticsPresentationController.playbackSettingToggles
                  .containsKey(toggle)) {
            throw const FormatException();
          }
          final presentation = presentationController;
          if (presentation == null) {
            await _presentationUnavailable(request);
            return;
          }
          await presentation.togglePlaybackSetting(setting: toggle);
        }
        final settings = await _container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .getSettings();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'scrobbleEnabled': settings?.scrobbleEnabled ?? true,
          'backgroundSyncUnmeteredOnly':
              settings?.backgroundSyncUnmeteredOnly ?? true,
          'listenBrainzTokenValid': settings?.listenBrainzTokenValid ?? false,
          'listenBrainzAccountStored':
              settings?.listenBrainzUserName?.isNotEmpty ?? false,
          'persistedVolume':
              settings?.desktopPlaybackVolume ??
              AppSettingsDao.defaultDesktopPlaybackVolume,
        });
        return;
      }
      if (request.method == 'GET' &&
          path == '/v1/presentation/listenbrainz-discover') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        // Read before counting: this flushes a restart that is still pending
        // while Home is hidden, so the count includes it.
        final discover = _container.read(listenBrainzDiscoverStreamProvider);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'streamBuilds': listenBrainzDiscoverStreamBuildCount,
          'state': switch (discover) {
            AsyncData() => 'data',
            AsyncError() => 'error',
            AsyncLoading() => 'loading',
          },
          'playlistCount': discover.asData?.value.length,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/library-filter') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final rawQuery = body['query'];
        final query = rawQuery is String ? rawQuery.trim() : '';
        if (!body.containsKey('query') ||
            (rawQuery != null && rawQuery is! String) ||
            query.length > 64) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'query must be a string up to 64 characters or null',
          });
          return;
        }
        _container
            .read(libraryTypeFilterDiagnosticsProvider.notifier)
            .setQuery(query);
        await presentation.waitForFrame();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'query': query,
          'section': _container.read(librarySectionProvider).name,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/library-scroll') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final pixels = body['pixels'];
        if (pixels is! num ||
            !pixels.isFinite ||
            pixels < 0 ||
            pixels > 100000) {
          throw const FormatException();
        }
        final actual = await _container
            .read(libraryScrollDiagnosticsProvider.notifier)
            .scroll(pixels.toDouble());
        await _respond(request, HttpStatus.ok, {'pixels': actual});
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/scroll') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final by = body['by'];
        final to = body['to'];
        bool inRange(Object? value, {required double min}) =>
            value is num && value.isFinite && value >= min && value <= 100000;
        if ((by == null) == (to == null) ||
            (by != null && !inRange(by, min: -100000)) ||
            (to != null && !inRange(to, min: 0))) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'send one of "by" (±100000) or "to" (0–100000) pixels',
          });
          return;
        }
        try {
          final result = await presentation.scrollPrimary(
            by: (by as num?)?.toDouble(),
            to: (to as num?)?.toDouble(),
          );
          await _respond(request, HttpStatus.ok, result.toJson());
        } on DiagnosticsPresentationUnavailable {
          await _presentationUnavailable(request);
        }
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/notice') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final rawMessage = body['message'];
        final message = rawMessage is String ? rawMessage.trim() : '';
        final rawLevel = body['level'];
        AppNoticeLevel? level;
        if (rawLevel is String) {
          for (final candidate in AppNoticeLevel.values) {
            if (candidate.name == rawLevel) {
              level = candidate;
              break;
            }
          }
        }
        if (message.isEmpty || message.length > 240 || level == null) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'message must be a non-empty string up to 240 characters and level must be info, success, or error',
          });
          return;
        }
        _container
            .read(appNoticeDiagnosticsProvider.notifier)
            .show(message: message, level: level);
        await presentation.waitForFrame();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'level': level.name,
          'messageLength': message.length,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/playback-recovery') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        final recovery = _container.read(playbackRecoveryServiceProvider);
        switch (action) {
          case 'retry':
            recovery.retryPlayback();
          case 'resetCache':
            await recovery.resetLibraryCacheAndRetry();
          case 'signOutKeepData':
            await recovery.signOut(wipeLocalData: false);
          case 'signOutWipeData':
            await recovery.signOut(wipeLocalData: true);
          default:
            await _respond(request, HttpStatus.badRequest, <String, Object?>{
              'error': 'action must be retry, resetCache, signOutKeepData, or signOutWipeData',
            });
            return;
        }
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'action': action,
          'bootstrap': _container
              .read(audioBootstrapControllerProvider)
              .status
              .name,
        });
        return;
      }
      if (path == '/v1/presentation/library-rebuild' &&
          (request.method == 'GET' || request.method == 'POST')) {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _libraryRebuildControl(request);
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/player-overlay') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final surface = body['surface'];
        final visible = body['visible'];
        if ((surface != 'queue' && surface != 'nowPlaying') ||
            visible is! bool) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'surface must be queue or nowPlaying and visible must be boolean',
          });
          return;
        }
        final controller = _container.read(playerOverlayStackProvider.notifier);
        final route = surface == 'queue'
            ? PlayerOverlayRoute.queue
            : PlayerOverlayRoute.nowPlaying;
        // `settle: false` waits for one rendered frame instead of all
        // animations, so the call measures how quickly the surface appears
        // even while unrelated animations run.
        final settle = body['settle'] != false;
        Future<void> waitForUi() => settle
            ? presentation.waitForFrame()
            : WidgetsBinding.instance.endOfFrame;
        if (surface == 'queue') {
          if (visible) {
            controller.hideQueue();
            await waitForUi();
            controller.showQueueOnly();
          } else {
            controller.hideQueue();
          }
        } else if (visible) {
          controller.expand();
        } else {
          controller.collapse();
        }
        if (surface == 'nowPlaying') {
          _container
              .read(desktopNowPlayingDiagnosticsProvider.notifier)
              .setVisible(visible);
        }
        await waitForUi();
        final stack = _container.read(playerOverlayStackProvider);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'surface': surface,
          'visible': stack.contains(route),
          'stack': stack.map((route) => route.name).toList(growable: false),
          'desktopNowPlayingVisible': _container.read(
            desktopNowPlayingDiagnosticsProvider,
          ),
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/transport') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        if (action is! String ||
            !const <String>{
              'baseline',
              'manualNext',
              'manualPrevious',
              'automaticAdvance',
              'restartCurrent',
              'unavailableNext',
              'unavailablePrevious',
              'rapidNext',
            }.contains(action)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'action is not a supported transport presentation state',
          });
          return;
        }
        final songs = await _container
            .read(navisDatabaseProvider)
            .libraryDao
            .getAllSongs();
        if (songs.length < 2) {
          await _respond(
            request,
            HttpStatus.unprocessableEntity,
            <String, Object?>{
              'error':
                  'transport presentation requires at least two local songs',
            },
          );
          return;
        }
        final ids = songs
            .take(3)
            .map((song) => song.id)
            .toList(growable: false);
        final fixture = _container.read(
          transportMotionPresentationFixtureProvider.notifier,
        );
        final startsOnSecond = action == 'manualPrevious';
        final baselineIndex = startsOnSecond ? 1 : 0;
        fixture.setBaseline(ids, currentIndex: baselineIndex);
        await presentation.waitForFrame();
        switch (action) {
          case 'baseline':
            break;
          case 'manualNext':
            fixture.apply(
              ids,
              currentIndex: 1,
              intent: TransportVisualIntent.next,
              fromSongId: ids[0],
            );
          case 'manualPrevious':
            fixture.apply(
              ids,
              currentIndex: 0,
              intent: TransportVisualIntent.previous,
              fromSongId: ids[1],
            );
          case 'automaticAdvance':
            fixture.apply(ids, currentIndex: 1);
          case 'restartCurrent':
            fixture.apply(
              ids,
              currentIndex: 0,
              intent: TransportVisualIntent.restartCurrent,
              fromSongId: ids[0],
            );
          case 'unavailableNext':
            fixture.apply(
              ids,
              currentIndex: ids.length - 1,
              intent: TransportVisualIntent.unavailableNext,
              fromSongId: ids.last,
            );
          case 'unavailablePrevious':
            fixture.apply(
              ids,
              currentIndex: 0,
              intent: TransportVisualIntent.unavailablePrevious,
              fromSongId: ids[0],
            );
          case 'rapidNext':
            fixture.apply(
              ids,
              currentIndex: 1,
              intent: TransportVisualIntent.next,
              fromSongId: ids[0],
            );
            if (ids.length > 2) {
              fixture.apply(
                ids,
                currentIndex: 2,
                intent: TransportVisualIntent.next,
                fromSongId: ids[1],
              );
            }
        }
        await presentation.waitForFrame();
        final state = _container.read(
          transportMotionPresentationFixtureProvider,
        );
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'action': action,
          'currentIndex': state?.playback.currentIndex,
          'intent': state?.cue?.intent.name,
          'sequence': state?.sequence,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/tooltip') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final target = body['target'];
        if (target != null &&
            (target is! String ||
                !DiagnosticsPresentationController.tooltipTargets.containsKey(
                  target,
                ))) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error':
                'target must be favorite, lyrics, queue, miniPlayer or null',
          });
          return;
        }
        try {
          final visible = await presentation.hoverTooltip(
            target: target as String?,
          );
          await _respond(request, HttpStatus.ok, <String, Object?>{
            'target': target,
            'visible': visible,
          });
        } on DiagnosticsPresentationUnavailable {
          await _presentationUnavailable(request);
        }
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/screenshot') {
        // Primary Android certification permits only this read-only capture
        // endpoint when its app-owned presentation surface is available.
        if (!allowsMutations && presentationController == null) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final rawLabel = body['label'];
        final label = rawLabel is String ? rawLabel.trim() : '';
        if (!DiagnosticsPresentationController.isValidLabel(label)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'label must match [a-z0-9][a-z0-9_-]{0,47}',
          });
          return;
        }
        try {
          final screenshot = await presentation.capture(label: label);
          await _respond(request, HttpStatus.created, screenshot.toJson());
        } on FormatException catch (error) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': error.message,
          });
        } on DiagnosticsPresentationUnavailable {
          await _presentationUnavailable(request);
        }
        return;
      }
      if (request.method == 'GET' &&
          path == '/v1/presentation/song-indicator') {
        final songId = (request.uri.queryParameters['songId'] ?? '').trim();
        if (songId.isEmpty) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songId is required',
          });
          return;
        }
        final state = _container.read(
          songPlaybackIndicatorStateProvider(songId),
        );
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'state': state.name,
          'selected': state.isSelected,
          'markerRole': state.markerRole,
          'semanticRole': switch (state) {
            SongPlaybackIndicatorState.inactive => 'none',
            SongPlaybackIndicatorState.current ||
            SongPlaybackIndicatorState.loading => 'nowPlaying',
          },
          'backgroundColorRole': state.isSelected
              ? 'primaryTint08'
              : 'transparent',
          'foregroundColorRole': state.isSelected ? 'primary' : 'default',
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/sync/status') {
        await _respond(
          request,
          HttpStatus.ok,
          await _syncStateJson(_reportedSyncState()),
        );
        return;
      }
      if (request.method == 'GET' && path == '/v1/sync/ledger') {
        await _respond(request, HttpStatus.ok, <String, Object?>{
          // `events` is a one-release compatibility mirror for the isolated
          // diagnostics fixture. Durable runs are the cross-restart source of
          // truth; the live mirror is deliberately bounded and never used to
          // resume or decide sync work.
          'events': List<Map<String, Object?>>.unmodifiable(_syncLedger),
          'durableRuns': await _durableRunHistoryJson(),
          'durableOperations': await _durableOperationLedgerJson(),
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/sync/attempts') {
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'attempts': await _durableAttemptHistoryJson(),
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/library/album') {
        final id = request.uri.queryParameters['id']?.trim() ?? '';
        if (id.isEmpty || id.length > 256) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'id is required',
          });
          return;
        }
        final album = await _container
            .read(navisDatabaseProvider)
            .libraryDao
            .getAlbumById(id);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'id': id,
          'exists': album != null,
          if (album != null) ...<String, Object?>{
            'songsHydrated': album.songsHydrated,
            'songCount': album.songCount,
            if (request.uri.queryParameters['verifySongs'] == 'true')
              'persistedSongCount':
                  (await _container
                          .read(navisDatabaseProvider)
                          .libraryDao
                          .watchSongsByAlbum(id)
                          .first)
                      .length,
          },
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/library/recent-albums') {
        final requestedLimit = int.tryParse(
          request.uri.queryParameters['limit'] ?? '',
        );
        final limit = (requestedLimit ?? 20).clamp(1, 100);
        final albums = await _container
            .read(navisDatabaseProvider)
            .libraryDao
            .watchAlbumsPage(sort: AlbumSortOrder.recentlyAdded, limit: limit)
            .first;
        // IDs and ordering evidence only: diagnostics must not expose the
        // user's private album metadata through its authenticated API.
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'sort': AlbumSortOrder.recentlyAdded.name,
          'albums': <Map<String, Object?>>[
            for (final album in albums)
              <String, Object?>{
                'id': album.id,
                'serverCreatedAt': album.serverCreatedAt
                    ?.toUtc()
                    .toIso8601String(),
                'recentlyAddedRank': album.recentlyAddedRank,
                'usesSyncedAtFallback': album.serverCreatedAt == null,
              },
          ],
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/session/status') {
        await _respond(
          request,
          HttpStatus.ok,
          await _sessionStatusJson(activateInitialSync: !_isPassive(request)),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/session/connect') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _connectDiagnosticsSession(request);
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/initial-sync/retry') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _initialSyncController().retry();
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/initial-sync/mobile') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _initialSyncController().startUsingMobileData();
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/initial-sync/cancel') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _initialSyncController().cancelAndLogOut();
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/session/sign-out') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        await _container
            .read(signOutServiceProvider)
            .signOut(wipeLocalData: body['wipeLocalData'] == true);
        await _container.read(serverConfigProvider.notifier).refresh();
        await _respond(
          request,
          HttpStatus.ok,
          await _sessionStatusJson(activateInitialSync: !_isPassive(request)),
        );
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/reset-initial-state') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _container
            .read(librarySyncControllerProvider.notifier)
            .cancelAndWait();
        await _container.read(downloadServiceProvider).stopAndWait();
        await _container
            .read(audioBootstrapControllerProvider.notifier)
            .resetSessionAndWait();
        await _container.read(serverDataResetServiceProvider).reset();
        await _container.read(serverConfigProvider.notifier).refresh();
        _container.invalidate(initialSyncRequiredProvider);
        _container.invalidate(initialServerSyncControllerProvider);
        await _respond(
          request,
          HttpStatus.ok,
          await _sessionStatusJson(activateInitialSync: !_isPassive(request)),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/search/source-audit') {
        await _runSourceAudit(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/search') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        if (presentationController == null) {
          await _presentationUnavailable(request);
          return;
        }
        await _runPresentationSearch(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/search/play') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        if (presentationController == null) {
          await _presentationUnavailable(request);
          return;
        }
        await _playPresentationSearchSong(request);
        return;
      }
      if (request.method == 'GET' && path == '/v1/diagnostics/overrides') {
        await _respond(
          request,
          HttpStatus.ok,
          _container.read(syncDiagnosticsOverridesProvider).toJson(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/diagnostics/overrides') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final notifier = _container.read(
          syncDiagnosticsOverridesProvider.notifier,
        );
        if (body.isEmpty) {
          notifier.reset();
        } else {
          notifier.patch(body);
        }
        if (body['cachedListenBrainzPresentation'] == true) {
          final cachedUserName = await _container
              .read(navisDatabaseProvider)
              .cacheDao
              .getLatestListenBrainzWeeklyCacheUserName();
          if (cachedUserName != null) {
            final completer = Completer<void>();
            late final ProviderSubscription<
              AsyncValue<List<ListenBrainzDiscoverPlaylist>>
            >
            subscription;
            subscription = _container.listen(
              listenBrainzDiscoverStreamProvider,
              (_, next) {
                if ((next.asData?.value.isNotEmpty ?? false) &&
                    !completer.isCompleted) {
                  completer.complete();
                }
              },
              fireImmediately: true,
            );
            try {
              await completer.future.timeout(const Duration(seconds: 5));
            } finally {
              subscription.close();
            }
          }
          await presentationController?.waitForFrame();
        }
        await _respond(
          request,
          HttpStatus.ok,
          _container.read(syncDiagnosticsOverridesProvider).toJson(),
        );
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/diagnostics/sync-foreground') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final active = body['active'];
        if (active is! bool) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'active must be a boolean',
          });
          return;
        }
        _container
            .read(librarySyncForegroundProvider.notifier)
            .setForeground(active);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'active': _container.read(librarySyncForegroundProvider),
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/diagnostics/automatic-sync-due') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final serverId = _container
            .read(serverConfigStateProvider)
            .asData
            ?.value
            ?.id;
        if (serverId == null) {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'No active server',
          });
          return;
        }
        await _container
            .read(navisDatabaseProvider)
            .librarySyncDao
            .setNextAutomaticCheckAt(
              serverId: serverId,
              nextAutomaticCheckAt: DateTime.now().toUtc().subtract(
                const Duration(seconds: 1),
              ),
            );
        await _respond(request, HttpStatus.ok, <String, Object?>{'due': true});
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/automatic') {
        await _startControllerSync(
          request,
          cause: 'automatic',
          operation: () => _container
              .read(librarySyncControllerProvider.notifier)
              .syncIfStale(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/library/cache-upgrade') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        try {
          await _container
              .read(cacheSystemUpgradeServiceProvider)
              .resetAndMarkCurrent();
          await _respond(request, HttpStatus.ok, <String, Object?>{
            'status': 'succeeded',
            'needsReset': await _container
                .read(cacheSystemUpgradeServiceProvider)
                .needsReset(),
            'sync': await _syncStateJson(
              _container.read(librarySyncControllerProvider),
            ),
          });
        } on Object catch (error) {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'status': 'failed',
            'error': error.runtimeType.toString(),
          });
        }
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/check') {
        final body = await _readJson(request);
        final allowOverride = body['allowMeteredBroadOverride'] == true;
        await _startControllerSync(
          request,
          cause: 'manualCheck',
          operation: () => _container
              .read(librarySyncControllerProvider.notifier)
              .syncNow(allowMeteredBroadOverride: allowOverride),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/repair') {
        final body = await _readJson(request);
        final allowOverride = body['allowMeteredBroadOverride'] == true;
        await _startControllerSync(
          request,
          cause: 'repair',
          operation: () => _container
              .read(librarySyncControllerProvider.notifier)
              .forceFullSync(allowMeteredBroadOverride: allowOverride),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/target') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final target = _targetFromJson(body);
        if (target == null) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'targetKind and entityId are required',
          });
          return;
        }
        // Exercise the same controller boundary that route-entry hydration
        // uses. Calling the raw engine here would bypass target/catalog lane
        // isolation and make this endpoint unsuitable for runtime validation.
        await _startControllerSync(
          request,
          cause: 'targetHydration',
          targetKind: target.kind.name,
          operation: () => _container
              .read(librarySyncControllerProvider.notifier)
              .requestTarget(target),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/fixture/queue-target') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final target = _targetFromJson(body);
        if (target == null || target.kind != LibrarySyncTargetKind.album) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'an album targetKind and entityId are required',
          });
          return;
        }
        final serverId = await _container
            .read(serverConfigRepositoryProvider)
            .getActiveServer()
            .then((config) => config?.id);
        if (serverId == null) {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'no authenticated server session',
          });
          return;
        }
        // This clone-only fixture deliberately creates durable work without
        // dispatching it. It reproduces the priority collision between a
        // queued detail hydration and a subsequent manual catalog refresh.
        await _container
            .read(navisDatabaseProvider)
            .librarySyncDao
            .enqueueWork(
              serverId: serverId,
              kind: LibrarySyncPlanKind.targetedHydration.name,
              entityId: librarySyncTargetWorkKey(target),
              priority: 100,
              workClass: 'interactive',
              reactivateTerminal: true,
              now: DateTime.now(),
            );
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'status': 'queued',
          'targetKind': target.kind.name,
          'pendingWork': await _container
              .read(navisDatabaseProvider)
              .librarySyncDao
              .countPendingWork(serverId),
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/cancel') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        _container.read(librarySyncControllerProvider.notifier).cancelSync();
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'status': 'cancelling',
        });
        return;
      }
      if (request.method == 'GET' &&
          path == '/v1/downloads/saf-fixture/status') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _respond(request, HttpStatus.ok, await _safFixtureStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/configure') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final fixtureTree = await const AndroidSafStorage()
            .diagnosticsFixtureTree();
        await _container
            .read(downloadServiceProvider)
            .configureCustomDownloadFolder(enabled: true, path: fixtureTree);
        await _respond(request, HttpStatus.ok, await _safFixtureStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/use-default') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _container
            .read(downloadServiceProvider)
            .configureCustomDownloadFolder(enabled: false);
        await _respond(request, HttpStatus.ok, await _cacheStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/download') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final songId = (body['songId'] as String? ?? '').trim();
        if (songId.isEmpty) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songId is required',
          });
          return;
        }
        await _container.read(downloadServiceProvider).enqueueSong(songId);
        await _respond(request, HttpStatus.accepted, await _cacheStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/preview') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final preview = await _safFixturePreview();
        await _respond(request, HttpStatus.ok, _safPreviewJson(preview));
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/read-denied') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        await const AndroidSafStorage().diagnosticsFixtureSetReadDenied(
          body['denied'] == true,
        );
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'denied': body['denied'] == true,
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/stage-unindexed-copy') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await const AndroidSafStorage().diagnosticsFixtureStageUnindexedCopy();
        await _respond(
          request,
          HttpStatus.created,
          await _safFixtureStatusJson(),
        );
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/commit') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final service = _container.read(downloadServiceProvider);
        final preview = await _safFixturePreview();
        final result = await service.importCustomDownloadFolder(preview);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'importedCount': result.importedCount,
          'skippedCount': result.skippedCount,
          'preview': _safPreviewJson(preview),
          'cache': await _cacheStatusJson(),
        });
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/downloads/saf-fixture/detach') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final songId = (body['songId'] as String? ?? '').trim();
        if (songId.isEmpty) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songId is required',
          });
          return;
        }
        // Test setup only: retain fixture documents but drop local ownership
        // so preview/commit exercise the production adoption service.
        await _container
            .read(navisDatabaseProvider)
            .cacheDao
            .removeCachedTrack(songId);
        await _respond(request, HttpStatus.ok, await _cacheStatusJson());
        return;
      }
      if (request.method == 'GET' && path == '/v1/downloads/status') {
        await _respond(request, HttpStatus.ok, await _downloadStatusJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/downloads/enqueue') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final songIds = body['songIds'];
        if (songIds is! List ||
            songIds.isEmpty ||
            songIds.any((id) => id is! String || id.trim().isEmpty)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songIds must be a non-empty list of song ids',
          });
          return;
        }
        final quality = body['quality'];
        final format = body['format'];
        if ((quality != null && (quality is! int || quality <= 0)) ||
            (format != null && format is! String)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'quality must be a positive int and format a string',
          });
          return;
        }
        // usePreference applies the saved download quality, as the app's
        // download actions do once a preference is saved.
        final saved = body['usePreference'] == true
            ? (await _container
                      .read(navisDatabaseProvider)
                      .appSettingsDao
                      .getDownloadQualityPreference())
                  .savedChoice
            : null;
        final service = _container.read(downloadServiceProvider);
        for (final id in songIds.cast<String>()) {
          await service.enqueueSong(
            id.trim(),
            quality: saved?.quality ?? (quality as int?)?.toString(),
            format: saved?.format ?? format as String?,
          );
        }
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'queued': songIds.length,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/downloads/cancel') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final queueId = body['queueId'];
        if (queueId is! int) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'queueId must be an int',
          });
          return;
        }
        await _container.read(downloadServiceProvider).cancelQueueItem(queueId);
        await _respond(request, HttpStatus.ok, await _downloadStatusJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/downloads/settings') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final maxConcurrent = body['maxConcurrent'];
        final paused = body['paused'];
        final mode = body['qualityMode'];
        final bitRate = body['bitRate'];
        final format = body['format'];
        final prompted = body['prompted'];
        if ((maxConcurrent != null && maxConcurrent is! int) ||
            (paused != null && paused is! bool) ||
            (mode != null &&
                !DownloadQualityMode.values.any((m) => m.name == mode)) ||
            (bitRate != null && !kDownloadBitRateOptions.contains(bitRate)) ||
            (format != null && !kDownloadFormatOptions.contains(format)) ||
            (prompted != null && prompted is! bool)) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error':
                'expected maxConcurrent int, paused bool, qualityMode '
                'ask|original|transcode, bitRate and format from the '
                'download options, prompted bool',
          });
          return;
        }
        final service = _container.read(downloadServiceProvider);
        final dao = _container.read(navisDatabaseProvider).appSettingsDao;
        if (maxConcurrent is int) {
          await service.setMaxConcurrentDownloads(maxConcurrent);
        }
        if (mode is String) {
          await dao.updateDownloadQuality(
            mode: DownloadQualityMode.parse(mode),
            bitRate: bitRate as int?,
            format: format as String?,
          );
        } else if (format is String) {
          await dao.updateDownloadFormat(format);
        }
        if (prompted is bool) {
          await dao.updateDownloadQualityPrompted(prompted: prompted);
        }
        if (paused is bool) await service.setPaused(paused: paused);
        if (body['resetPeak'] == true) service.resetPeakActiveDownloads();
        await _respond(request, HttpStatus.ok, await _downloadStatusJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/downloads/folder/adopt') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final String folder;
        if (body['fixture'] == true) {
          folder = await const AndroidSafStorage().diagnosticsFixtureTree();
        } else {
          final requested = body['path'];
          final root = File(handshakePath).parent.absolute.path;
          if (requested is! String ||
              !requested.startsWith('$root${Platform.pathSeparator}')) {
            await _respond(request, HttpStatus.badRequest, <String, Object?>{
              'error': 'path must be inside the diagnostics root',
            });
            return;
          }
          folder = requested;
        }
        // The same owner Downloads settings uses: preview, configure, import,
        // then record the scan for Manual Matching.
        final watch = Stopwatch()..start();
        final result = await _container
            .read(customDownloadFolderControllerProvider.notifier)
            .choose(folder);
        final matching = _container.read(manualDownloadMatchingProvider);
        final items =
            matching.preview?.items ?? const <PermanentDownloadImportItem>[];
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'items': items.length,
          'importedCount': result.importedCount,
          'skippedCount': result.skippedCount,
          'manualMatchingPending': matching.pendingCount,
          'totalMs': watch.elapsedMilliseconds,
          'dispositions': <String, int>{
            for (final disposition in PermanentDownloadImportDisposition.values)
              disposition.name: items
                  .where((item) => item.disposition == disposition)
                  .length,
          },
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/downloads/folder/status') {
        // The persisted settings, as the app reads them (a clone ignores a
        // folder outside its run); the path itself is not reported.
        final settings = await _container
            .read(navisDatabaseProvider)
            .appSettingsDao
            .getSettings();
        final folderPath = settings?.customDownloadFolderPath;
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'enabled': settings?.customDownloadFolderEnabled ?? false,
          'configured': folderPath != null && folderPath.trim().isNotEmpty,
          'busy': _container.read(customDownloadFolderControllerProvider).busy,
          'manualMatchingPending': _container
              .read(manualDownloadMatchingProvider)
              .pendingCount,
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/cache/status') {
        await _respond(request, HttpStatus.ok, await _cacheStatusJson());
        return;
      }
      if (request.method == 'POST' && path == '/v1/cache/maintenance') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _runCacheMaintenance(request);
        return;
      }
      if (request.method == 'POST' && path == '/v1/diagnostics/cache/corrupt') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _corruptCloneCacheEntry(request);
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/diagnostics/local-mutation') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _applyLocalMutation(request);
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/diagnostics/restore-server-star') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _restoreServerStar(request);
        return;
      }
      if (path == '/v1/equalizer' && request.method == 'GET') {
        await _respond(request, HttpStatus.ok, await _equalizerStatus());
        return;
      }
      if (path == '/v1/equalizer' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _waitForPlaybackHandler();
        await _container.read(equalizerProvider.future);
        final controller = _container.read(equalizerProvider.notifier);
        final body = await _readJson(request);
        final action = body['action'];
        final current = _container.read(equalizerProvider).requireValue;
        final matches = current.allPresets.where((p) => p.id == body['id']);
        final preset = matches.firstOrNull;
        var success = false;
        try {
          switch (action) {
            case 'configure':
              final configuration = EqConfiguration.fromJson(
                body['configuration'] as Map<String, dynamic>,
              );
              success = await controller.setConfiguration(configuration);
            case 'mode':
              success = await controller.changeMode(
                EqMode.values.byName(body['mode'] as String),
              );
            case 'custom':
              success = await controller.selectCustom();
            case 'discard':
              success = await controller.discardChanges();
            case 'retry':
              success = await controller.retry();
            case 'preview':
              final token = controller.beginPreview();
              success = await controller.preview(
                EqConfiguration.fromJson(
                  body['configuration'] as Map<String, dynamic>,
                ),
                token,
              );
            case 'cancelPreview':
              success = await controller.retry();
            case 'enable':
              success = await controller.setEnabled(
                enabled: body['enabled'] as bool,
              );
            case 'select':
              if (preset != null) {
                success = await controller.selectPreset(preset);
              }
            case 'save':
              success = await controller.saveAs(body['name'] as String) != null;
            case 'update':
              success = await controller.updatePreset();
            case 'rename':
              if (preset != null) {
                success = await controller.rename(
                  preset,
                  body['name'] as String,
                );
              }
            case 'duplicate':
              if (preset != null) {
                success =
                    await controller.saveAs(
                      body['name'] as String,
                      imported: preset,
                      activate: false,
                    ) !=
                    null;
              }
            case 'delete':
              if (preset != null) {
                success = await controller.deletePreset(
                  preset,
                  discardDrafts: body['discardDrafts'] == true,
                );
              }
            case 'restore':
              success = await controller.restorePreset(
                EqPreset.fromJson(body['preset'] as Map<String, dynamic>),
              );
            case 'import':
              final imported = EqImportParser().parse(
                body['text'] as String,
                id: 'preview',
                name: body['name'] as String,
                fixedBand: body['fixedBand'] as bool?,
              );
              success =
                  await controller.saveAs(
                    body['name'] as String,
                    imported: imported,
                    activate: body['enable'] == true,
                    enable: body['enable'] == true,
                  ) !=
                  null;
            case 'undo':
              await controller.undo();
              success = true;
            case 'redo':
              await controller.redo();
              success = true;
            case 'reset':
              await controller.reset();
              success = true;
            case 'acknowledgeReset':
              await controller.acknowledgeLegacyReset();
              success = true;
          }
        } on Object {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'Invalid EQ action or payload',
          });
          return;
        }
        await _respond(
          request,
          success ? HttpStatus.ok : HttpStatus.badRequest,
          await _equalizerStatus(),
        );
        return;
      }
      if (path == '/v1/playback/adjustments' && request.method == 'GET') {
        await _respond(
          request,
          HttpStatus.ok,
          await _playbackAdjustmentStatus(),
        );
        return;
      }
      if (path == '/v1/playback/adjustments' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _waitForPlaybackHandler();
        final controller = _container.read(
          playbackAdjustmentsProvider.notifier,
        );
        await _container.read(playbackAdjustmentsProvider.future);
        final body = await _readJson(request);
        final action = body['action'] ?? 'adjust';
        var success = false;
        if (action == 'adjust') {
          final current = _container
              .read(playbackAdjustmentsProvider)
              .requireValue
              .values;
          final speed = body['speed'];
          final percent = body['speedPercent'];
          final pitch = body['pitchSemitones'];
          final lock = body['lockPitchToSpeed'];
          if ((speed != null && percent != null) ||
              (speed != null && speed is! num) ||
              (percent != null && percent is! num) ||
              (pitch != null && pitch is! num) ||
              (lock != null && lock is! bool) ||
              (speed == null &&
                  percent == null &&
                  pitch == null &&
                  lock == null)) {
            await _respond(request, HttpStatus.badRequest, {
              'error': 'Provide speed or speedPercent (not both), pitchSemitones, or lockPitchToSpeed',
            });
            return;
          }
          final locked = lock as bool? ?? current.lockPitchToSpeed;
          if (locked && pitch != null) {
            await _respond(request, HttpStatus.badRequest, {
              'error': 'Unlock pitch before setting independent semitones',
            });
            return;
          }
          final values = current.copyWith(
            speed: speed is num
                ? speed.toDouble()
                : percent is num
                ? 1 + percent.toDouble() / 100
                : null,
            pitchSemitones: pitch is num ? pitch.toDouble() : null,
            lockPitchToSpeed: locked,
          );
          success = await controller.setValues(values);
        } else if (action == 'select' && body['id'] is String) {
          success = await controller.selectPreset(body['id'] as String);
        } else if ((action == 'save' || action == 'update') &&
            body['name'] is String) {
          if (action == 'update' && body['id'] is! String) {
            await _respond(request, HttpStatus.badRequest, {
              'error': 'id is required to update',
            });
            return;
          }
          success = await controller.savePreset(
            body['name'] as String,
            updateId: action == 'update' ? body['id'] as String : null,
          );
        } else if (action == 'rename' &&
            body['id'] is String &&
            body['name'] is String) {
          success = await controller.renamePreset(
            body['id'] as String,
            body['name'] as String,
          );
        } else if (action == 'delete' && body['id'] is String) {
          success = await controller.deletePreset(body['id'] as String);
        } else {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'Invalid adjustment action',
          });
          return;
        }
        await controller.flush();
        final result = await _playbackAdjustmentStatus();
        final failedSave = result['failure'] == 'persistence';
        await _respond(
          request,
          success && !failedSave ? HttpStatus.ok : HttpStatus.badRequest,
          result,
        );
        return;
      }
      if (path == '/v1/presentation/equalizer' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final interaction = await presentation.activateEqualizerControl(
          action: body['action'] as String,
          index: (body['index'] as num?)?.toInt() ?? 0,
          value: body['value'] as String?,
          dx: (body['dx'] as num?)?.toDouble() ?? 0,
          dy: (body['dy'] as num?)?.toDouble() ?? 0,
        );
        await _respond(request, HttpStatus.ok, {
          'status': 'visible',
          'profile': ?interaction,
        });
        return;
      }
      if (path == '/v1/presentation/adjustments' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        String? surface;
        if (body['quick'] == true) {
          surface = await presentation.openPlaybackQuickPanel();
        } else if (body['settingsSheet'] == true) {
          await presentation.openNowPlayingSettingsSheet();
          surface = 'settingsSheet';
        } else {
          await presentation.revealPlaybackAdjustments(
            open: body['open'] == true,
          );
        }
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'status': 'visible',
          'surface': ?surface,
          'quickControls': presentation.playbackQuickControls(),
        });
        return;
      }
      if (path == '/v1/presentation/quick-panel' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        final target = body['target'] ?? 'speed';
        final preset = body['preset'];
        if (action is! String ||
            !const {'open', 'press', 'preset', 'openPage'}.contains(action) ||
            (target != 'speed' && target != 'equalizer') ||
            (action == 'preset' && (preset is! String || preset.isEmpty))) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error':
                'action must be open, press, preset (with preset) or openPage; '
                'target must be speed or equalizer',
          });
          return;
        }
        String? surface;
        switch (action) {
          case 'open':
            surface = await presentation.openPlaybackQuickPanel(
              target: target as String,
            );
          case 'press':
            await presentation.pressPlayerQuickButton(target: target as String);
          case 'preset':
            await presentation.selectQuickEqualizerPreset(preset as String);
          case 'openPage':
            await presentation.openEqualizerFromQuickPanel();
        }
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'status': 'done',
          'surface': ?surface,
          ..._quickPanelState(presentation),
        });
        return;
      }
      if (path == '/v1/presentation/quick-panel' && request.method == 'GET') {
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await _respond(request, HttpStatus.ok, _quickPanelState(presentation));
        return;
      }
      if (path == '/v1/presentation/system-back' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await presentation.systemBack();
        await _respond(request, HttpStatus.ok, _navigationState());
        return;
      }
      if (path == '/v1/presentation/tab' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final branch = ShellBranch.values
            .where((candidate) => candidate.name == body['branch'])
            .firstOrNull;
        if (branch == null) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'branch must be home, library, search or settings',
          });
          return;
        }
        try {
          await presentation.tapNavigationDestination(branch.index);
        } on DiagnosticsPresentationUnavailable {
          await _presentationUnavailable(request);
          return;
        }
        await _respond(request, HttpStatus.ok, _navigationState());
        return;
      }
      if (path == '/v1/presentation/shortcut' && request.method == 'POST') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        const allowed = <DesktopCommandAction>{
          DesktopCommandAction.speedUp,
          DesktopCommandAction.speedDown,
          DesktopCommandAction.speedReset,
        };
        final action = allowed
            .where((candidate) => candidate.name == body['action'])
            .firstOrNull;
        if (action == null) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'action must be speedUp, speedDown or speedReset',
          });
          return;
        }
        final binding = _container.read(
          desktopShortcutBindingsProvider,
        )[action];
        if (binding == null) {
          await _respond(request, HttpStatus.conflict, <String, Object?>{
            'error': 'shortcut is disabled',
          });
          return;
        }
        await presentation.sendShortcut(binding, defaultTargetPlatform);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'action': action.name,
          'binding': binding.formatLabel(defaultTargetPlatform),
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/playback/volume') {
        await _respond(request, HttpStatus.ok, await _playbackVolumeStatus());
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/volume') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final rawValue = body['value'];
        if (rawValue is! num ||
            !rawValue.toDouble().isFinite ||
            rawValue < 0 ||
            rawValue > 1) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'value must be a number from 0 to 1',
          });
          return;
        }
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        await _container
            .read(playbackVolumeProvider.notifier)
            .setVolume(
              rawValue.toDouble(),
              persistImmediately: true,
              throwOnPersistenceFailure: true,
            );
        await _respond(request, HttpStatus.ok, await _playbackVolumeStatus());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/playback/volume/toggle-mute') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        await _container
            .read(playbackVolumeProvider.notifier)
            .toggleMute(throwOnPersistenceFailure: true);
        await _respond(request, HttpStatus.ok, await _playbackVolumeStatus());
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/start') {
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        final body = await _readJson(request);
        final songId = (body['songId'] as String? ?? '').trim();
        if (songId.isEmpty) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songId is required',
          });
          return;
        }
        final song = await _container
            .read(navisDatabaseProvider)
            .libraryDao
            .getSongById(songId);
        if (song == null) {
          await _respond(request, HttpStatus.notFound, <String, Object?>{
            'error': 'song not found',
          });
          return;
        }
        final resumeExisting = canResumeDiagnosticsPlayback(
          snapshot: handler.snapshot,
          songId: songId,
        );
        if (resumeExisting) {
          // Replacing the current item would briefly create a second
          // LockCachingAudioSource for the same `.part` path. The old source
          // can then delete the new source's partial file while disposing.
          await handler.play();
        } else {
          await _container.read(queueProvider.notifier).replaceWithTableData(
            <SongsTableData>[song],
          );
        }
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'status': resumeExisting ? 'resuming' : 'starting',
          'songId': songId,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/queue/clear') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _waitForPlaybackHandler();
        await _container.read(queueProvider.notifier).clear();
        await _respond(
          request,
          HttpStatus.ok,
          await _playbackAdjustmentStatus(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/queue') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        final body = await _readJson(request);
        final rawSongIds = body['songIds'];
        if (rawSongIds is! List || rawSongIds.length < 2) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'at least two songIds are required',
          });
          return;
        }
        final songIds = rawSongIds
            .whereType<String>()
            .map((songId) => songId.trim())
            .where((songId) => songId.isNotEmpty)
            .toList(growable: false);
        if (songIds.length != rawSongIds.length) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'songIds must be non-empty strings',
          });
          return;
        }
        final database = _container.read(navisDatabaseProvider);
        var songsById = <String, SongsTableData>{
          for (final song in await database.libraryDao.getSongsByIds(songIds))
            song.id: song,
        };
        final missingIds = songIds
            .where((songId) => !songsById.containsKey(songId))
            .toSet();
        if (missingIds.isNotEmpty) {
          // Like playing a search result: a remote song the library lacks is
          // fetched and stored provisionally before it is queued.
          final unknownId = await _storeRemoteSongs(missingIds);
          if (unknownId != null) {
            await _respond(request, HttpStatus.notFound, <String, Object?>{
              'error': 'song not found',
              'songId': unknownId,
            });
            return;
          }
          songsById = <String, SongsTableData>{
            for (final song in await database.libraryDao.getSongsByIds(songIds))
              song.id: song,
          };
        }
        final songs = <SongsTableData>[];
        for (final songId in songIds) {
          final song = songsById[songId];
          if (song == null) {
            await _respond(request, HttpStatus.notFound, <String, Object?>{
              'error': 'song not found',
              'songId': songId,
            });
            return;
          }
          songs.add(song);
        }
        await _container
            .read(queueProvider.notifier)
            .replaceWithTableData(songs);
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'status': 'starting',
          'songIds': songIds,
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/artists/playback/status') {
        await _respond(
          request,
          HttpStatus.ok,
          _container.read(artistPlaybackControllerProvider).diagnostics(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/artists/playback') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final command = body['command'];
        final controller = _container.read(
          artistPlaybackControllerProvider.notifier,
        );
        if (command == 'prepare') {
          final id = body['artistId'];
          final action = body['action'];
          if (id is! String ||
              id.trim().isEmpty ||
              id.length > 256 ||
              !const {'play', 'shuffle', 'add'}.contains(action) ||
              body.keys.any(
                (key) => !const {'command', 'artistId', 'action'}.contains(key),
              )) {
            await _respond(request, HttpStatus.badRequest, {
              'error': 'artistId and a valid artist action are required',
            });
            return;
          }
          unawaited(
            controller.prepare(
              id.trim(),
              ArtistPlaybackAction.values.byName(action as String),
            ),
          );
        } else if (command == 'cancel' && body.length == 1) {
          controller.cancel();
        } else {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'invalid artist playback command',
          });
          return;
        }
        await _respond(
          request,
          HttpStatus.accepted,
          _container.read(artistPlaybackControllerProvider).diagnostics(),
        );
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/presentation/artist-action') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final action = body['action'];
        if (body.length != 1 ||
            action is! String ||
            !DiagnosticsPresentationController.artistActions.contains(action)) {
          await _respond(request, HttpStatus.badRequest, {
            'error': 'invalid artist presentation action',
          });
          return;
        }
        final presentation = presentationController;
        if (presentation == null) {
          await _presentationUnavailable(request);
          return;
        }
        await presentation.activateArtistControl(action: action);
        await _respond(
          request,
          HttpStatus.accepted,
          _container.read(artistPlaybackControllerProvider).diagnostics(),
        );
        return;
      }
      if (request.method == 'GET' && path == '/v1/playback/status') {
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        final activity = _container.read(rollingCacheActivityProvider);
        final status = handler.collectPlaybackDiagnostics();
        status['providerCacheActivity'] = <String, Object?>{
          'status': activity.status.name,
          'songId': activity.songId,
          'progress': activity.progress,
        };
        await _respond(request, HttpStatus.ok, status);
        return;
      }
      if (request.method == 'GET' && path == '/v1/playback/bootstrap/status') {
        final bootstrap = _container.read(audioBootstrapControllerProvider);
        final controller = _container.read(
          audioBootstrapControllerProvider.notifier,
        );
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'status': bootstrap.status.name,
          'attempt': bootstrap.attempt,
          'timedOut': bootstrap.timedOut,
          'retryScheduled': controller.isRetryScheduled,
          'handlerReady': bootstrap.isReady,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/seek') {
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        final body = await _readJson(request);
        final positionMs = body['positionMs'];
        if (positionMs is! num) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'positionMs is required',
          });
          return;
        }
        final before = handler.collectPlaybackDiagnostics();
        final started = DateTime.now().toUtc();
        await handler.seek(Duration(milliseconds: positionMs.round()));
        final elapsedMs = DateTime.now()
            .toUtc()
            .difference(started)
            .inMilliseconds;
        final after = handler.collectPlaybackDiagnostics();
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'elapsedMs': elapsedMs,
          'requestedPositionMs': positionMs.round(),
          'before': before,
          'after': after,
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/queue-index') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final index = body['index'];
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        final length = handler.snapshot.queueSongIds.length;
        if (index is! int || index < 0 || index >= length) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'index must identify a queued song',
          });
          return;
        }
        await handler.playFromIndex(index);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'currentIndex': handler.snapshot.currentIndex,
          'queueCount': handler.snapshot.queueSongIds.length,
          'mix': _mixStatusJson(),
        });
        return;
      }
      if (request.method == 'POST' &&
          (path == '/v1/playback/next' || path == '/v1/playback/previous')) {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        if (path == '/v1/playback/next') {
          await handler.skipToNext();
        } else {
          await handler.skipToPrevious();
        }
        await _respond(
          request,
          HttpStatus.ok,
          handler.collectPlaybackDiagnostics(),
        );
        return;
      }
      if (request.method == 'POST' &&
          (path == '/v1/playback/shuffle' || path == '/v1/playback/repeat')) {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        if (path == '/v1/playback/shuffle') {
          final enabled = body['enabled'];
          if (enabled is! bool) {
            await _respond(request, HttpStatus.badRequest, <String, Object?>{
              'error': 'enabled must be boolean',
            });
            return;
          }
          await handler.setShuffleMode(
            enabled
                ? AudioServiceShuffleMode.all
                : AudioServiceShuffleMode.none,
          );
        } else {
          final mode = switch (body['mode']) {
            'none' => AudioServiceRepeatMode.none,
            'one' => AudioServiceRepeatMode.one,
            'all' => AudioServiceRepeatMode.all,
            _ => null,
          };
          if (mode == null) {
            await _respond(request, HttpStatus.badRequest, <String, Object?>{
              'error': 'mode must be none, one or all',
            });
            return;
          }
          await handler.setRepeatMode(mode);
        }
        await _respond(
          request,
          HttpStatus.ok,
          handler.collectPlaybackDiagnostics(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/pause') {
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        await handler.pause();
        await _respond(
          request,
          HttpStatus.ok,
          handler.collectPlaybackDiagnostics(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/playback/play') {
        final handler = await _waitForPlaybackHandler();
        await handler.waitUntilReady();
        await handler.play();
        await _respond(
          request,
          HttpStatus.ok,
          handler.collectPlaybackDiagnostics(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/diagnostics/metrics/reset') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        _frameMicros.clear();
        _frameBuildMicros.clear();
        _frameRasterMicros.clear();
        _frameSpanMicros.clear();
        _slowFrameSamples.clear();
        _frameWindowStartedAt = DateTime.now();
        _frameWindowCount = 0;
        _databaseCanaryMicros.clear();
        _databaseCanaryMicrosByPhase.clear();
        _slowDatabaseCanarySamples.clear();
        _playbackFailureCount = 0;
        _heartbeatGapMicros.clear();
        _eventLoopLagMicros.clear();
        _heartbeatLastTickMicros = _heartbeatWatch.elapsedMicroseconds;
        _heartbeatLastLagMicros = _heartbeatWatch.elapsedMicroseconds;
        _playbackCounterBaseline = _playbackCounters();
        _tableUpdateCounts.clear();
        await _respond(request, HttpStatus.ok, {'status': 'reset'});
        return;
      }
      if (request.method == 'POST' && path == '/v1/diagnostics/heartbeat') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final body = await _readJson(request);
        final enabled = body['enabled'];
        if (enabled is! bool) throw const FormatException();
        if (enabled) {
          _startHeartbeat();
        } else {
          _stopHeartbeat();
        }
        await _respond(request, HttpStatus.ok, {'heartbeat': enabled});
        return;
      }
      if (request.method == 'GET' && path == '/v1/diagnostics/local-search') {
        final query = (request.uri.queryParameters['query'] ?? '').trim();
        if (query.isEmpty || query.length > 128) {
          throw const FormatException();
        }
        await _respond(request, HttpStatus.ok, await _localSearchTiming(query));
        return;
      }
      if (request.method == 'GET' && path == '/v1/diagnostics/integrations') {
        // Read-only and available in every mode: per-service counters, the
        // last 100 calls and the last 50 spans. Paths only, never query
        // strings, headers or bodies.
        await _respond(
          request,
          HttpStatus.ok,
          _container.read(integrationCallRecorderProvider).toJson(),
        );
        return;
      }
      if (request.method == 'GET' && path == '/v1/diagnostics/report') {
        await _respond(request, HttpStatus.ok, await _buildReport());
        return;
      }
      if (request.method == 'POST' && path == '/v1/shutdown') {
        await _respond(request, HttpStatus.accepted, <String, Object?>{
          'status': 'shutting-down',
        });
        unawaited(onShutdown());
        return;
      }
      await _respond(request, HttpStatus.notFound, <String, Object?>{
        'error': 'not found',
      });
    } on FormatException catch (_) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'invalid JSON body',
      });
    } on Object catch (error) {
      await _respond(request, HttpStatus.internalServerError, <String, Object?>{
        'error': error.runtimeType.toString(),
      });
    }
  }

  /// Activates the legacy diagnostics setup controller with a lasting
  /// subscription. A provider that is only read is paused between reads,
  /// which would also pause its session watch and phase and network
  /// listeners, so it would miss a sign-out or sign-in between two requests.
  InitialServerSyncState _initialSyncState() {
    final subscription = _initialSyncSubscription ??= _container.listen(
      initialServerSyncControllerProvider,
      (_, _) {},
    );
    return subscription.read();
  }

  InitialServerSyncController _initialSyncController() {
    _initialSyncState();
    return _container.read(initialServerSyncControllerProvider.notifier);
  }

  /// `passive=1` reports the session without instantiating the legacy
  /// diagnostics setup controller, which would otherwise start its own setup
  /// run whenever the session needs one and mask the route-owned controller.
  bool _isPassive(HttpRequest request) =>
      request.uri.queryParameters['passive'] == '1';

  /// Observes or retries the full-screen rebuild controller that the mounted
  /// route owns. Reading an unmounted controller would start a rebuild, so
  /// status reports `inactive` instead of instantiating it.
  Future<void> _libraryRebuildControl(HttpRequest request) async {
    final body = request.method == 'POST'
        ? await _readJson(request)
        : const <String, Object?>{};
    final reason = RequiredLibraryRebuildReason.parse(
      (body['reason'] as String?) ?? request.uri.queryParameters['reason'],
    );
    if (reason == null) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'reason must be a full-screen rebuild route value',
      });
      return;
    }
    final provider = requiredLibraryRebuildControllerProvider(reason);
    if (!_container.exists(provider)) {
      await _respond(request, HttpStatus.ok, <String, Object?>{
        'reason': reason.routeValue,
        'status': 'inactive',
      });
      return;
    }
    if (request.method == 'POST') {
      final controller = _container.read(provider.notifier);
      switch (body['action']) {
        case 'retry':
          unawaited(controller.retry());
        case 'cancelAndSignOut':
          // Same action as the screen's sign-out button; it keeps local data.
          await controller.cancelAndSignOut();
          await _respond(request, HttpStatus.ok, <String, Object?>{
            'reason': reason.routeValue,
            'status': _container.exists(provider)
                ? _container.read(provider).status.name
                : 'inactive',
          });
          return;
        default:
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'action must be retry or cancelAndSignOut',
          });
          return;
      }
    }
    final state = _container.read(provider);
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'reason': reason.routeValue,
      'status': state.status.name,
      'failure': state.failure?.name,
      'errorMessage': state.errorMessage,
    });
  }

  Future<void> _connectDiagnosticsSession(HttpRequest request) async {
    final body = await _readJson(request);
    final url = (body['url'] as String? ?? '').trim();
    final username = (body['username'] as String? ?? '').trim();
    final password = body['password'] as String? ?? '';
    if (url.isEmpty || username.isEmpty || password.isEmpty) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'url, username, and password are required',
      });
      return;
    }
    final probe = await _container
        .read(serverConnectionServiceProvider)
        .probe(url: url, username: username, password: password);
    final uri = Uri.tryParse(url);
    await _container
        .read(serverConfigProvider.notifier)
        .save(
          ServerConfigModel(
            name: uri?.host.isEmpty ?? true ? null : uri!.host,
            url: url,
            username: username,
            password: password,
            apiVersion: probe.apiVersion,
            useLegacyAuth: probe.useLegacyAuth,
            capabilitiesJson: jsonEncode(probe.capabilities.toJson()),
          ),
        );
    // Connecting is a configuration operation. Do not instantiate the legacy
    // initial-sync controller just to describe this response: that controller
    // treats its start as an interactive retry, while the Home shell owns the
    // normal startup sync.
    await _respond(
      request,
      HttpStatus.ok,
      await _sessionStatusJson(activateInitialSync: false),
    );
  }

  Future<Map<String, Object?>> _cacheStatusJson() async {
    final database = _container.read(navisDatabaseProvider);
    final entries = await database.cacheDao.getCachedTracks();
    var missingFiles = 0;
    var rolling = 0;
    var permanent = 0;
    const safStorage = AndroidSafStorage();
    for (final entry in entries) {
      final exists = entry.storageKind == 'androidSaf'
          ? Platform.isAndroid && await safStorage.exists(entry.filePath)
          : File(entry.filePath).existsSync();
      if (!exists) {
        missingFiles += 1;
      }
      if (entry.cacheType.name == 'rolling') {
        rolling += 1;
      } else {
        permanent += 1;
      }
    }
    return <String, Object?>{
      'entries': entries.length,
      'rollingEntries': rolling,
      'permanentEntries': permanent,
      'missingFiles': missingFiles,
      'renewalRequired': await _container
          .read(cacheSystemUpgradeServiceProvider)
          .needsReset(),
    };
  }

  /// Download queue, preference, and artwork state. Files are named by base
  /// name only, so no path outside the run root is reported.
  Future<Map<String, Object?>> _downloadStatusJson() async {
    final database = _container.read(navisDatabaseProvider);
    final service = _container.read(downloadServiceProvider);
    final queue = await database.downloadQueueDao.watchQueue().first;
    final preference = await database.appSettingsDao
        .getDownloadQualityPreference();
    final permanent = await database.cacheDao.getPermanentEntries();
    return <String, Object?>{
      'paused': service.isPaused,
      'maxConcurrent': service.maxConcurrentDownloads,
      'effectiveConcurrency': service.effectiveConcurrency,
      'activeQueueIds': service.activeQueueIds.toList()..sort(),
      'peakActive': service.peakActiveDownloads,
      'queue': <String, Object?>{
        for (final status in DownloadStatus.values)
          status.name: queue.where((item) => item.status == status).length,
      },
      'queueItems': <Object?>[
        for (final item in queue)
          <String, Object?>{
            'id': item.id,
            'songId': item.songId,
            'status': item.status.name,
            'quality': item.quality,
            'format': item.format,
            'retryCount': item.retryCount,
          },
      ],
      'qualityPreference': <String, Object?>{
        'mode': preference.mode.name,
        'bitRate': preference.bitRate,
        'format': preference.format,
        'prompted': preference.prompted,
      },
      'permanentDownloads': <Object?>[
        for (final entry in permanent)
          <String, Object?>{
            'songId': entry.songId,
            'format': entry.format,
            'bitRate': entry.bitRate,
            'fileName': p.basename(entry.filePath),
          },
      ],
      'permanentArtworkCount': await service.artworkStore.count(),
    };
  }

  Future<Map<String, Object?>> _safFixtureStatusJson() async {
    const storage = AndroidSafStorage();
    final treeUri = await storage.diagnosticsFixtureTree();
    final tree = await storage.inspectTree(treeUri);
    final documents = await storage.listRecursively(treeUri);
    final settings = await _container
        .read(navisDatabaseProvider)
        .appSettingsDao
        .getSettings();
    return <String, Object?>{
      'displayName': tree.displayName,
      'canRead': tree.canRead,
      'canWrite': tree.canWrite,
      'canReplace': tree.canReplace,
      'documentCount': documents.length,
      'configured':
          settings?.customDownloadFolderEnabled == true &&
          settings?.customDownloadFolderStorageKind == 'androidSaf',
      'cache': await _cacheStatusJson(),
    };
  }

  Future<PermanentDownloadImportPreview> _safFixturePreview() async {
    final treeUri = await const AndroidSafStorage().diagnosticsFixtureTree();
    return await _container
        .read(downloadServiceProvider)
        .previewCustomDownloadFolder(treeUri);
  }

  Map<String, Object?> _safPreviewJson(
    PermanentDownloadImportPreview preview,
  ) => <String, Object?>{
    'recognizedCount': preview.recognizedCount,
    'uncertainCount': preview.uncertainCount,
    'unmatchedCount': preview.unmatchedCount,
    'profileMismatchCount': preview.profileMismatchCount,
    'inaccessibleCount': preview.inaccessibleCount,
    'items': <Map<String, Object?>>[
      for (final item in preview.items)
        <String, Object?>{
          'disposition': item.disposition.name,
          'format': item.format,
          'size': item.fileSize,
          'hasSongId': item.songId != null,
        },
    ],
  };

  Future<void> _runCacheMaintenance(HttpRequest request) async {
    final cache = _container.read(rollingCacheManagerProvider);
    await cache.pruneMissingFiles();
    await cache.pruneMissingPermanentFiles();
    await cache.cleanupOrphanedRollingFiles();
    await _respond(request, HttpStatus.ok, await _cacheStatusJson());
  }

  Future<void> _corruptCloneCacheEntry(HttpRequest request) async {
    final body = await _readJson(request);
    final songId = (body['songId'] as String? ?? '').trim();
    if (songId.isEmpty) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'songId is required',
      });
      return;
    }
    final entry = await _container
        .read(navisDatabaseProvider)
        .cacheDao
        .getCachedTrack(songId);
    if (entry == null) {
      await _respond(request, HttpStatus.notFound, <String, Object?>{
        'error': 'cache entry not found',
      });
      return;
    }
    final file = File(entry.filePath);
    final existed = file.existsSync();
    if (existed) {
      await file.delete();
    }
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'songId': songId,
      'fileRemoved': existed,
      'cache': await _cacheStatusJson(),
    });
  }

  Future<Map<String, Object?>> _sessionStatusJson({
    bool activateInitialSync = true,
  }) async {
    final database = _container.read(navisDatabaseProvider);
    final handler = _container.read(audioHandlerProvider);
    final playback = handler?.snapshot ?? const PlaybackSnapshot.idle();
    final rollingCache = _container.read(rollingCacheActivityProvider);
    final persistedQueue = await database.playQueueDao.watchQueueItems().first;
    final downloadQueue = await database.downloadQueueDao.watchQueue().first;
    final pendingWork = await database
        .select(database.librarySyncWorkTable)
        .get();
    final sync = _reportedSyncState();
    final phase = _container.read(sessionRoutePhaseProvider);
    final initialSync = activateInitialSync
        ? _initialSyncState().status
        : _passiveInitialSyncStatus(phase, sync);
    return <String, Object?>{
      'phase': phase.name,
      'transition': _container.read(sessionTransitionProvider).name,
      'initialSync': initialSync.name,
      'sync': <String, Object?>{
        'status': sync.status.name,
        'stage': sync.stage.name,
      },
      'queues': <String, int>{
        'memoryPlayback': playback.queueSongIds.length,
        'persistedPlayback': persistedQueue.length,
        'downloads': downloadQueue.length,
        'syncWork': pendingWork.length,
      },
      'activity': <String, bool>{
        'playing': playback.playing,
        'loading': playback.isLoading,
        'radio': playback.isRadioMode,
        'mediaItemPresent': handler?.currentMediaItem != null,
        'rollingCacheActive': rollingCache.isCaching,
      },
    };
  }

  InitialServerSyncStatus _passiveInitialSyncStatus(
    SessionRoutePhase phase,
    LibrarySyncState sync,
  ) {
    if (phase == SessionRoutePhase.ready) {
      return InitialServerSyncStatus.complete;
    }
    if (phase != SessionRoutePhase.initialSyncRequired) {
      return InitialServerSyncStatus.idle;
    }
    return switch (sync.status) {
      LibrarySyncStatus.running => InitialServerSyncStatus.running,
      LibrarySyncStatus.failed => InitialServerSyncStatus.failed,
      _ => InitialServerSyncStatus.idle,
    };
  }

  Future<Map<String, Object?>> _windowPresentationJson() async {
    final controller = _container.read(desktopWindowControllerProvider);
    final bounds = await controller.getCurrentBounds();
    final transition = controller.transitionRequest;
    return <String, Object?>{
      'mode': controller.mode.name,
      'bounds': _rectJson(bounds),
      'displayWorkArea': _rectJson(controller.currentWorkArea),
      'desktopViewAvailable': controller.desktopViewAvailable,
      'miniAlwaysOnTop': controller.miniAlwaysOnTop,
      'miniAlwaysOnTopSupported': controller.supportsMiniAlwaysOnTop,
      'stateRecordVersion': controller.stateRecordVersion,
      'restorationSource': controller.restorationSource,
      'lastPersistenceCompleted': controller.lastPersistenceCompleted,
      'pendingTransition': transition == null
          ? null
          : <String, Object?>{
              'direction': transition.direction.name,
              'viewport': <String, double>{
                'width': transition.viewportSize.width,
                'height': transition.viewportSize.height,
              },
            },
    };
  }

  Map<String, double>? _rectJson(Rect? rect) => rect == null
      ? null
      : <String, double>{
          'x': rect.left,
          'y': rect.top,
          'width': rect.width,
          'height': rect.height,
        };

  /// Uses the production controller for broad actions so a diagnostics
  /// request joins startup, reconnect, and UI-triggered work instead of
  /// beginning a second raw-engine operation with competing progress frames.
  Future<void> _startControllerSync(
    HttpRequest request, {
    required String cause,
    String? targetKind,
    required Future<LibrarySyncState> Function() operation,
  }) async {
    if (_activeSync != null) {
      await _respond(request, HttpStatus.conflict, <String, Object?>{
        'error': 'sync already running',
      });
      return;
    }
    _lastSyncError = null;
    _recordSyncLedgerEvent(
      phase: 'requested',
      cause: cause,
      targetKind: targetKind,
    );
    final future = operation();
    _activeSync = future;
    _recordSyncLedgerEvent(
      phase: 'started',
      cause: cause,
      targetKind: targetKind,
    );
    unawaited(
      future
          .then<void>(
            (state) {
              _lastSync = state;
              _recordSyncLedgerEvent(
                phase: 'terminal',
                cause: cause,
                targetKind: targetKind,
                state: state,
              );
            },
            onError: (Object error, StackTrace stackTrace) {
              _lastSyncError = error;
              _recordSyncLedgerEvent(
                phase: 'failed',
                cause: cause,
                targetKind: targetKind,
                errorType: error.runtimeType.toString(),
              );
            },
          )
          .whenComplete(() {
            _activeSync = null;
          }),
    );
    await _respond(request, HttpStatus.accepted, <String, Object?>{
      'status': 'started',
    });
  }

  void _recordSyncLedgerEvent({
    required String phase,
    required String cause,
    String? targetKind,
    LibrarySyncState? state,
    String? errorType,
  }) {
    _syncLedger.add(<String, Object?>{
      'id': _nextSyncLedgerId++,
      'at': DateTime.now().toUtc().toIso8601String(),
      'phase': phase,
      'cause': cause,
      'targetKind': targetKind,
      'planKind': state?.planKind?.name,
      'planReason': state?.planReason,
      'result': state?.status.name,
      'endpointRequests': state?.endpointRequests,
      'errorType': errorType,
    });
    if (_syncLedger.length > 50) {
      _syncLedger.removeRange(0, _syncLedger.length - 50);
    }
  }

  Future<Map<String, Object?>> _equalizerStatus() async {
    final handler = await _waitForPlaybackHandler();
    await handler.waitUntilReady();
    await _container.read(equalizerProvider.future);
    await handler.refreshEqualizerState();
    final state = _container.read(equalizerProvider).requireValue;
    final persisted = await _container.read(eqRepositoryProvider).load();
    final applied = handler.equalizerState;
    return {
      'supported': handler.equalizerCapabilities.supported,
      'configuration': state.configuration.toJson(),
      'selectedPresetId': state.selectedPresetId,
      'originPresetId': state.originPresetId,
      'dirty': state.dirty,
      'draftPersisted': state.draftPersisted,
      'interaction': _container
          .read(equalizerProvider.notifier)
          .interactionDiagnostics,
      'workspaces': {
        for (final e in state.workspaces.entries) e.key: e.value.toJson(),
      },
      'presets': [for (final p in state.presets) p.toJson()],
      'pending': state.pending,
      'failure': state.failure,
      'legacyResetNotice': state.legacyResetNotice,
      'persistedConfiguration': persisted.configuration.toJson(),
      'persistedPresetId': persisted.selectedPresetId,
      'application': {
        'configuration': applied.applied.toJson(),
        'enabled': applied.applied.enabled,
        'sampleRate': applied.sampleRate,
        'responseSampleRate': applied.responseSampleRate,
        'headroomDb': applied.headroomDb,
        'reason': applied.reason,
        'pending': applied.pending,
      },
    };
  }

  /// Route, player overlay and quick-control state for quick-panel checks.
  /// Location, shell tab and player overlays after a navigation control.
  Map<String, Object?> _navigationState() => <String, Object?>{
    'location': _navigationDriver.location,
    'librarySection': _container.read(librarySectionProvider).name,
    'playerOverlay': [
      for (final route in _container.read(playerOverlayStackProvider))
        route.name,
    ],
    'navigation': _container.read(navigationHistoryProvider).stack,
  };

  Map<String, Object?> _quickPanelState(
    DiagnosticsPresentationController presentation,
  ) => <String, Object?>{
    'quickControls': presentation.playbackQuickControls(),
    'location': _container.read(appRouterProvider).state.uri.toString(),
    'playerOverlay': [
      for (final route in _container.read(playerOverlayStackProvider))
        route.name,
    ],
    'miniPlayer': _container
        .read(desktopWindowControllerProvider)
        .isMiniPlayerMode,
  };

  Future<Map<String, Object?>> _playbackAdjustmentStatus() async {
    final handler = await _waitForPlaybackHandler();
    await handler.waitUntilReady();
    await _container.read(playbackAdjustmentsProvider.future);
    final state = _container.read(playbackAdjustmentsProvider).requireValue;
    final persisted = await _container
        .read(settingsRepositoryProvider)
        .getSettings();
    final caps = handler.playbackAdjustmentCapabilities;
    return {
      'speed': state.values.speed,
      'speedPercent': state.values.speedPercent,
      'lockPitchToSpeed': state.values.lockPitchToSpeed,
      'pitchSemitones': state.values.pitchSemitones,
      'selectedPresetId': state.selectedPresetId,
      'originPresetId': state.originPresetId,
      'pending': state.pending,
      'failure': state.failure?.name,
      'presets': [for (final p in state.presets) p.toJson()],
      'persistedSpeed': persisted.playbackSpeed,
      'persistedLockPitchToSpeed': persisted.lockPitchToSpeed,
      'persistedPitchSemitones': persisted.playbackPitchSemitones,
      'persistedPresetId': persisted.selectedPlaybackPresetId,
      'pitchSupported': caps.pitchSupported,
      'minimumSpeed': caps.minimumSpeed,
      'maximumSpeed': caps.maximumSpeed,
      'minimumPitchFactor': caps.minimumPitchFactor,
      'maximumPitchFactor': caps.maximumPitchFactor,
      'minimumTempoRatio': caps.minimumTempoRatio,
      'engine': handler.collectPlaybackDiagnostics(),
    };
  }

  Future<Map<String, Object?>> _playbackVolumeStatus() async {
    final handler = await _waitForPlaybackHandler();
    await handler.waitUntilReady();
    final controller = _container.read(playbackVolumeProvider.notifier);
    final settings = await _container
        .read(settingsRepositoryProvider)
        .getSettings();
    final playback = handler.collectPlaybackDiagnostics();
    return <String, Object?>{
      'volume': _container.read(playbackVolumeProvider),
      'lastAudibleVolume': controller.lastAudibleVolume,
      'persistedVolume': settings.desktopPlaybackVolume,
      'persistedLastAudibleVolume': settings.desktopLastAudibleVolume,
      'handlerUserVolume': playback['userVolume'],
      'effectivePlayerVolume': playback['effectivePlayerVolume'],
      'hydrated': controller.hydrated,
      'desktopPersistenceEnabled': controller.persistenceEnabled,
    };
  }

  Future<void> _runSourceAudit(HttpRequest request) async {
    final body = await _readJson(request);
    final rawQuery = body['query'];
    if (rawQuery is! String) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'query is required',
      });
      return;
    }
    final query = rawQuery.trim();
    final songCount = _readSearchAuditBoundedInt(
      body['songCount'],
      fallback: 20,
      min: 1,
      max: 1000,
    );
    final songOffset = _readSearchAuditBoundedInt(
      body['songOffset'],
      fallback: 0,
      min: 0,
      max: 100000000,
    );
    final api = _container.read(subsonicApiProvider);
    if (api == null) {
      await _respond(request, HttpStatus.serviceUnavailable, <String, Object?>{
        'error': 'search unavailable',
      });
      return;
    }

    final result = await api.search3(
      query: query,
      songCount: songCount,
      songOffset: songOffset,
    );
    final records = <Map<String, Object?>>[];
    for (final artist in result.artists) {
      records.add(
        await _sourceAuditRecord(
          kind: 'artist',
          id: artist.id,
          label: artist.name,
          apiIsExternal: artist.isExternal,
        ),
      );
    }
    for (final album in result.albums) {
      records.add(
        await _sourceAuditRecord(
          kind: 'album',
          id: album.id,
          label: album.name,
          apiIsExternal: album.isExternal,
        ),
      );
    }
    for (final song in result.songs) {
      records.add(
        await _sourceAuditRecord(
          kind: 'song',
          id: song.id,
          label: song.title,
          apiIsExternal: song.isExternal,
        ),
      );
    }
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'query': query,
      'songCount': songCount,
      'songOffset': songOffset,
      'resultCounts': <String, int>{
        'artists': result.artists.length,
        'albums': result.albums.length,
        'songs': result.songs.length,
      },
      'records': records,
    });
  }

  int _readSearchAuditBoundedInt(
    Object? value, {
    required int fallback,
    required int min,
    required int max,
  }) {
    final parsed = switch (value) {
      int() => value,
      num() => value.toInt(),
      _ => fallback,
    };
    if (parsed < min) {
      return min;
    }
    if (parsed > max) {
      return max;
    }
    return parsed;
  }

  Future<void> _runPresentationSearch(HttpRequest request) async {
    final body = await _readJson(request);
    final rawQuery = body['query'];
    final query = rawQuery is String ? rawQuery.trim() : '';
    if (query.isEmpty) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'query is required',
      });
      return;
    }
    final rawFilter = body['filter'];
    final filterName = rawFilter == null
        ? 'all'
        : rawFilter is String
        ? rawFilter.trim()
        : '';
    final filter = switch (filterName) {
      'all' => null,
      'artists' => SearchResultType.artists,
      'albums' => SearchResultType.albums,
      'songs' => SearchResultType.songs,
      _ => SearchResultType.values.firstOrNull,
    };
    if (filterName != 'all' &&
        !SearchResultType.values.any((value) => value.name == filterName)) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'filter must be all, artists, albums, or songs',
      });
      return;
    }

    _navigationDriver.go(AppRoutes.search);
    _presentationSearchSongs = const <String, Song>{};
    _container.read(searchFilterProvider.notifier).select(filter);
    _container.read(searchQueryProvider.notifier).submit(query);
    _container.invalidate(debouncedSearchProvider);

    final completer = Completer<SearchResultsState>();
    late final ProviderSubscription<AsyncValue<SearchResultsState?>>
    subscription;
    subscription = _container.listen<AsyncValue<SearchResultsState?>>(
      debouncedSearchProvider,
      (_, next) {
        if (next.hasError && !completer.isCompleted) {
          completer.completeError(next.error!, next.stackTrace);
          return;
        }
        final state = next.asData?.value;
        if (state != null && !state.isWaitingForApi && !completer.isCompleted) {
          completer.complete(state);
        }
      },
      fireImmediately: true,
    );

    try {
      final state = await completer.future.timeout(const Duration(seconds: 15));
      final result = state.result;
      _presentationSearchSongs = <String, Song>{
        for (final song in result.songs) song.id: song,
      };
      await presentationController!.waitForFrame();
      await _respond(request, HttpStatus.ok, <String, Object?>{
        'filter': filter?.name ?? 'all',
        'route': _navigationDriver.location,
        'localOnly': state.isLocalOnly,
        'artists': <Map<String, Object?>>[
          for (final artist in result.artists)
            _presentationSearchRecord(
              id: artist.id,
              label: artist.name,
              apiIsExternal: artist.isExternal,
              query: query,
            ),
        ],
        'albums': <Map<String, Object?>>[
          for (final album in result.albums)
            _presentationSearchRecord(
              id: album.id,
              label: album.name,
              apiIsExternal: album.isExternal,
              query: query,
            ),
        ],
        'songs': <Map<String, Object?>>[
          for (final song in result.songs)
            _presentationSearchRecord(
              id: song.id,
              label: song.title,
              apiIsExternal: song.isExternal,
              query: query,
            ),
        ],
      });
    } on TimeoutException {
      await _respond(request, HttpStatus.gatewayTimeout, <String, Object?>{
        'error': 'search did not settle before the diagnostics timeout',
      });
    } finally {
      subscription.close();
    }
  }

  Future<void> _playPresentationSearchSong(HttpRequest request) async {
    final body = await _readJson(request);
    final songId = (body['songId'] as String? ?? '').trim();
    final song = _presentationSearchSongs[songId];
    if (songId.isEmpty || song == null) {
      await _respond(request, HttpStatus.notFound, <String, Object?>{
        'error': 'song is not present in the latest presentation search',
      });
      return;
    }
    await _container.read(queueProvider.notifier).replaceWithSongs(<Song>[
      song,
    ]);
    await presentationController!.waitForFrame();
    await _respond(request, HttpStatus.accepted, <String, Object?>{
      'songId': song.id,
      'source':
          isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal)
          ? 'remote'
          : 'onServer',
    });
  }

  Map<String, Object?> _presentationSearchRecord({
    required String id,
    required String label,
    required bool? apiIsExternal,
    required String query,
  }) {
    final source = classifyCatalogSource(id: id, apiIsExternal: apiIsExternal);
    return <String, Object?>{
      'id': id,
      'source': source == CatalogSource.external ? 'remote' : 'onServer',
      'relevance': searchRelevanceTier(label, query).name,
    };
  }

  Future<Map<String, Object?>> _sourceAuditRecord({
    required String kind,
    required String id,
    required String label,
    required bool? apiIsExternal,
  }) async {
    final dao = _container.read(navisDatabaseProvider).libraryDao;
    final local = switch (kind) {
      'artist' => await dao.getArtistById(id),
      'album' => await dao.getAlbumById(id),
      'song' => await dao.getSongById(id),
      _ => null,
    };
    final isProvisional = switch (local) {
      ArtistsTableData(:final isProvisional) => isProvisional,
      AlbumsTableData(:final isProvisional) => isProvisional,
      SongsTableData(:final isProvisional) => isProvisional,
      _ => false,
    };
    final source = classifyCatalogSource(id: id, apiIsExternal: apiIsExternal);
    return <String, Object?>{
      'kind': kind,
      'id': id,
      'displayLabel': label,
      'source': source == CatalogSource.external ? 'remote' : 'onServer',
      'apiIsExternal': apiIsExternal,
      'locallyIndexed': local != null,
      'isProvisional': isProvisional,
    };
  }

  LibrarySyncTarget? _targetFromJson(Map<String, Object?> body) {
    final kindName = body['targetKind'] as String?;
    final entityId = (body['entityId'] as String? ?? '').trim();
    if (kindName == null || entityId.isEmpty) {
      return null;
    }
    final kind = LibrarySyncTargetKind.values
        .where((value) => value.name == kindName)
        .cast<LibrarySyncTargetKind?>()
        .firstOrNull;
    if (kind == null) {
      return null;
    }
    return switch (kind) {
      LibrarySyncTargetKind.artist => LibrarySyncTarget.artist(entityId),
      LibrarySyncTargetKind.album => LibrarySyncTarget.album(entityId),
      LibrarySyncTargetKind.playlist => LibrarySyncTarget.playlist(entityId),
      _ => null,
    };
  }

  /// Fetches each of [songIds] with getSong and stores it provisionally, as
  /// search-play stores remote results. A server that answers for a remote
  /// song with its library copy still gets the requested id stored, with the
  /// copy's metadata but without its library album and artist ids. Returns
  /// the first id the server does not know, or null when every song was
  /// stored.
  Future<String?> _storeRemoteSongs(Iterable<String> songIds) async {
    final api = _container.read(subsonicApiProvider);
    final fetched = <Song>[];
    for (final songId in songIds) {
      if (api == null) return songId;
      try {
        final song = await api.getSong(songId);
        fetched.add(
          song.id == songId
              ? song
              // The copy's album and artist are library rows; a remote row
              // must not point at them, or storing it would mark them remote.
              : song.copyWith(
                  id: songId,
                  isExternal: isExternalCatalogSource(id: songId),
                  albumId: null,
                  artistId: null,
                ),
        );
      } on SubsonicException {
        return songId;
      }
    }
    await _container
        .read(queueProvider.notifier)
        .storeProvisionalSongs(fetched);
    return null;
  }

  Future<NavisPlaybackHandler> _waitForPlaybackHandler() async {
    final existingHandler = _container.read(audioHandlerProvider);
    if (existingHandler != null) return existingHandler;
    _container
        .read(audioBootstrapControllerProvider.notifier)
        .ensureInitialized();
    for (var attempt = 0; attempt < 60; attempt++) {
      final handler = _container.read(audioHandlerProvider);
      if (handler != null) return handler;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('Playback handler did not become ready.');
  }

  Future<void> _applyLocalMutation(HttpRequest request) async {
    final body = await _readJson(request);
    final type = body['type'] as String?;
    final id = (body['id'] as String? ?? '').trim();
    final field = body['field'] as String?;
    if (id.isEmpty || type == null || field == null) {
      throw const FormatException();
    }
    final dao = _container.read(navisDatabaseProvider).starSyncDao;
    if (field == 'starred') {
      final value = body['value'];
      if (value is! bool || !const {'artist', 'album', 'song'}.contains(type)) {
        throw const FormatException();
      }
      await dao.setStarred(itemId: id, itemType: type, liked: value);
    } else if (field == 'rating') {
      final value = body['value'];
      if ((value != null && value is! int) ||
          !const {'album', 'song'}.contains(type)) {
        throw const FormatException();
      }
      await dao.setRating(
        itemId: id,
        itemType: type,
        rating: (value as int?) ?? 0,
      );
    } else {
      throw const FormatException();
    }
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'status': 'applied',
      'type': type,
      'id': id,
      'field': field,
    });
  }

  Future<void> _restoreServerStar(HttpRequest request) async {
    final body = await _readJson(request);
    final songId = (body['songId'] as String? ?? '').trim();
    final liked = body['liked'];
    if (songId.isEmpty || liked is! bool) {
      throw const FormatException();
    }
    // Diagnostics never dispatches the queued local action, so fixture
    // restoration must not issue a redundant server mutation.
    await _container
        .read(navisDatabaseProvider)
        .libraryDao
        .updateSongStarred(songId, liked ? DateTime.now() : null);
    final starSyncDao = _container.read(navisDatabaseProvider).starSyncDao;
    final diagnosticActions = await starSyncDao.getPendingActions();
    for (final action in diagnosticActions.where(
      (action) =>
          action.operation == 'star' &&
          action.itemType == 'song' &&
          action.itemId == songId,
    )) {
      await starSyncDao.removeAction(action.id);
    }
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'status': 'restored',
      'songId': songId,
      'liked': liked,
    });
  }

  Future<Map<String, Object?>> _buildReport() async {
    final database = _container.read(navisDatabaseProvider);
    final counts = await database.libraryDao.getCatalogCounts();
    final server = await database.serverDao.getActiveServer();
    final persistedSync = server?.id == null
        ? null
        : await database.librarySyncDao.getOrCreateState(server!.id);
    final playback = _container.read(audioHandlerProvider)?.snapshot;
    final reportState = _reportedSyncState();
    final reportedAttempts = reportState.runAttemptId == null
        ? <Map<String, Object?>>[]
        : await _durableAttemptHistoryJson(
            limit: 1,
            attemptId: reportState.runAttemptId,
          );
    return <String, Object?>{
      'mode': mode.name,
      'startedAt': _startedAt.toIso8601String(),
      'capturedAt': DateTime.now().toIso8601String(),
      'rssBytes': ProcessInfo.currentRss,
      'peakRssBytes': ProcessInfo.maxRss,
      'catalog': <String, int>{
        'artists': counts.artists,
        'albums': counts.albums,
        'songs': counts.songs,
      },
      'sync': await _syncStateJson(reportState),
      'syncErrorType': _lastSyncError?.runtimeType.toString(),
      'reportedAttempt': reportedAttempts.isEmpty
          ? null
          : reportedAttempts.first,
      'diagnosticsOverrides': _container
          .read(syncDiagnosticsOverridesProvider)
          .toJson(),
      'endpointRequests': reportState.endpointRequests,
      // These persisted statistics can predate the current incremental run.
      'promotionScope': 'lastCommittedCatalogPromotion',
      'promotionGeneration': persistedSync?.currentGeneration,
      'promotion': _decodeSafeJson(persistedSync?.lastPromotionDiagnosticsJson),
      'frames': _sampleSummary(_frameMicros),
      'frameBuild': _sampleSummary(_frameBuildMicros),
      'frameRaster': _sampleSummary(_frameRasterMicros),
      'frameSpan': _sampleSummary(_frameSpanMicros),
      'slowFrameSamples': _slowFrameSamples,
      'frameWindow': _frameWindowJson(),
      'frameGap': _gapSummary(_heartbeatGapMicros),
      'eventLoopLag': _gapSummary(_eventLoopLagMicros),
      'playbackCounters': _playbackCounterDelta(),
      'tableUpdates': Map<String, int>.of(_tableUpdateCounts),
      'imageCache': _imageCacheJson(),
      'providers': providerCounter?.toJson(),
      'databaseCanary': _sampleSummary(_databaseCanaryMicros),
      'databaseCanaryByPhase': <String, Object?>{
        for (final entry in _databaseCanaryMicrosByPhase.entries)
          entry.key: _sampleSummary(entry.value),
      },
      'databaseCanarySlowSamples': _slowDatabaseCanarySamples,
      'playback': <String, Object?>{
        'active': playback?.hasActivePlayback ?? false,
        'playing': playback?.playing ?? false,
        'songId': playback?.currentSongId,
        'loadFailures': _playbackFailureCount,
      },
    };
  }

  LibrarySyncState _reportedSyncState() {
    final controller = _container.read(librarySyncControllerProvider);
    if (_activeSync != null) return controller;
    final lastApiRun = _lastSync;
    if (lastApiRun == null) return controller;
    final controllerRequestId = controller.runRequestId;
    final apiRequestId = lastApiRun.runRequestId;
    if (controllerRequestId != null &&
        (apiRequestId == null || controllerRequestId > apiRequestId)) {
      return controller;
    }
    return lastApiRun;
  }

  Future<Map<String, Object?>> _syncStateJson(LibrarySyncState state) async {
    final policy = _container.read(syncNetworkPolicyProvider);
    final overrides = _container.read(syncDiagnosticsOverridesProvider);
    final catalog = await _container
        .read(navisDatabaseProvider)
        .libraryDao
        .getCatalogCounts();
    final json = <String, Object?>{
      'requestActive':
          _activeSync != null || state.status == LibrarySyncStatus.running,
      'runRequestId': state.runRequestId,
      'runAttemptId': state.runAttemptId,
      'status': state.status.name,
      'stage': state.stage.name,
      'mode': state.mode?.name,
      'planKind': state.planKind?.name,
      'planReason': state.planReason,
      'failureCategory': state.failureCategory,
      'nextAutomaticCheckAt': state.nextAutomaticCheckAt
          ?.toUtc()
          .toIso8601String(),
      'nextRetryAt': state.nextRetryAt?.toUtc().toIso8601String(),
      'processed': state.processed,
      'total': state.total,
      'hydrationAlbumsPerSecond': state.hydrationThroughputAlbumsPerSecond,
      'pendingWork': state.pendingWorkCount,
      'pendingHydration': state.pendingHydrationCount,
      'remainingVerification': state.remainingVerificationCount,
      'workSummary': await _workSummaryJson(),
      'candidateStatus': state.candidateStatus,
      'candidateGeneration': state.candidateGeneration,
      // Safe aggregate evidence for the explicit repair-confirmation contract;
      // this intentionally reveals no server IDs, titles, or paths.
      'deletionCandidateCount': state.deletionCandidateCount,
      'requests': state.apiRequests,
      'bytes': state.lastRunBytes,
      'writes': state.dbWriteBatches,
      'lastApplyDurationMs': state.lastApplyDurationMs,
      'errorType': state.failureCategory,
      'updatesAvailable': state.updatesAvailable,
      'probeIndexChanged': state.probeIndexChanged,
      'probeIndexesUnsupported': state.probeIndexesUnsupported,
      'networkType': policy.networkType.name,
      'isMetered': policy.isMetered,
      'allowsBackgroundSync': policy.allowsBackgroundSync,
      'allowsInteractiveHydration': policy.allowsInteractiveHydration,
      'androidBackground': await _androidBackgroundSyncJson(),
      'catalog': <String, int>{
        'artists': catalog.artists,
        'albums': catalog.albums,
        'songs': catalog.songs,
      },
      'durableRuns': await _durableRunHistoryJson(),
      'durableOperations': await _durableOperationLedgerJson(),
    };
    if (overrides.requestReporting) {
      json['endpointRequests'] = state.endpointRequests;
    }
    return json;
  }

  /// Redacted WorkManager observation for debug diagnostics. It intentionally
  /// excludes the opaque profile key, WorkManager input, raw work id, server
  /// identity, and all exception text.
  Future<Map<String, Object?>?> _androidBackgroundSyncJson() async {
    final serverId = _container
        .read(serverConfigStateProvider)
        .asData
        ?.value
        ?.id;
    if (serverId == null) {
      return null;
    }
    final persisted = await _container
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getOrCreateState(serverId);
    return <String, Object?>{
      'enabled': persisted.androidBackgroundSyncEnabled,
      'requestedIntervalMinutes': persisted.androidRequestedIntervalMinutes,
      'scheduleReconciledAt': persisted.androidScheduleReconciledAt
          ?.toUtc()
          .toIso8601String(),
      'state': persisted.androidWorkState,
      'attemptCount': persisted.androidWorkAttemptCount,
      'workerStartedAt': persisted.androidWorkerStartedAt
          ?.toUtc()
          .toIso8601String(),
      'workerCompletedAt': persisted.androidWorkerCompletedAt
          ?.toUtc()
          .toIso8601String(),
      'workerDurationMs': persisted.androidWorkerDurationMs,
      'result': persisted.androidWorkerResult,
      'stopReason': persisted.androidWorkerStopReason,
    };
  }

  Future<List<Map<String, Object?>>> _durableOperationLedgerJson() async {
    final serverId = _container
        .read(serverConfigStateProvider)
        .asData
        ?.value
        ?.id;
    if (serverId == null) {
      return const <Map<String, Object?>>[];
    }
    final rows = await _container
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getRecentOperationLedgerEntries(serverId);
    return rows
        .map(
          (row) => <String, Object?>{
            'operation': row.operation,
            'reason': row.reason,
            'occurredAt': row.occurredAt.toUtc().toIso8601String(),
            'details': _decodeSafeJson(row.detailsJson),
          },
        )
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _durableRunHistoryJson() async {
    final serverId = _container
        .read(serverConfigStateProvider)
        .asData
        ?.value
        ?.id;
    if (serverId == null) {
      return const <Map<String, Object?>>[];
    }
    final entries = await _container
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getRecentSyncRunHistory(serverId);
    return entries
        .map(
          (entry) => <String, Object?>{
            'requestId': entry.requestId,
            'attemptId': entry.attemptId,
            'startedAt': entry.startedAt?.toUtc().toIso8601String(),
            'origin': entry.origin.name,
            'intent': entry.intent.name,
            'targetKind': entry.targetKind.name,
            'planKind': entry.planKind.name,
            'outcome': entry.outcome.name,
            'reason': entry.reason.name,
            'requestCount': entry.requestCount,
            'byteCount': entry.byteCount,
            'completedAt': entry.completedAt.toUtc().toIso8601String(),
          },
        )
        .toList(growable: false);
  }

  Future<List<Map<String, Object?>>> _durableAttemptHistoryJson({
    int limit = 20,
    int? attemptId,
  }) async {
    final serverId = _container
        .read(serverConfigStateProvider)
        .asData
        ?.value
        ?.id;
    if (serverId == null) return [];
    final rows = await _container
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getRecentSyncAttempts(serverId, limit: limit, attemptId: attemptId);
    return [
      for (final row in rows)
        {
          'requestId': row.requestId,
          'attemptId': row.id,
          'status': switch (row.status) {
            0 => 'running',
            1 => 'recovered',
            2 => 'terminal',
            _ => 'unknown',
          },
          'owner': row.ownerKind == 1 ? 'androidWorker' : 'foreground',
          'startedAt': row.startedAt.toUtc().toIso8601String(),
          'completedAt': row.completedAt?.toUtc().toIso8601String(),
          'telemetry': _decodeSafeJson(row.telemetryJson),
        },
    ];
  }

  Future<List<Map<String, Object?>>> _workSummaryJson() async {
    final serverId = _container
        .read(serverConfigStateProvider)
        .asData
        ?.value
        ?.id;
    if (serverId == null) return [];
    return await _container
        .read(navisDatabaseProvider)
        .librarySyncDao
        .getWorkSummary(serverId, DateTime.now());
  }

  Object? _decodeSafeJson(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, Object?>> _readJson(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    if (text.trim().isEmpty) return <String, Object?>{};
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) throw const FormatException();
    return value;
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  /// The integration policy as stored now, with each feature's effective
  /// state. Read from storage rather than the policy provider, which can lag
  /// a write by a frame.
  Future<Map<String, Object?>> _integrationsSnapshot() async {
    final settings = await _container
        .read(settingsRepositoryProvider)
        .getSettings();
    final policy = integrationPolicyFromSettings(
      settings,
      lastFmVerified: _container.read(hasLastFmApiKeyProvider),
    );
    return <String, Object?>{
      'master': policy.masterEnabled,
      'disabled': parseDisabledIntegrationKeys(
        settings.disabledIntegrations,
      ).toList()..sort(),
      'noticeDismissed': settings.integrationsNoticeDismissed,
      'setupHighlightsSeen': settings.setupHighlightsSeen.toList(),
      'setupHighlightsSeenRelease': settings.setupHighlightsSeenRelease,
      'setupCardDismissedRelease': settings.setupCardDismissedRelease,
      'nowPlayingBackground': settings.nowPlayingBackground.storageKey,
      'cornerStyle': settings.cornerStyle.name,
      'density': settings.density.storageKey,
      'services': <String, Object?>{
        for (final service in IntegrationService.values)
          service.key: <String, Object?>{
            'switchOn': policy.isServiceSwitchOn(service),
            'verified': policy.isVerified(service),
            'toggleable': policy.serviceLockReason(service) == null,
            'lock': policy.serviceLockReason(service)?.name,
          },
      },
      'features': <String, Object?>{
        for (final feature in IntegrationFeature.values)
          feature.key: <String, Object?>{
            'switchOn': policy.isFeatureSwitchOn(feature),
            'allowed': policy.allows(feature),
            'toggleable': policy.isUserToggleable(feature),
            'lock': policy.lockReason(feature)?.name,
          },
      },
    };
  }

  Future<void> _forbidden(HttpRequest request) {
    return _respond(request, HttpStatus.forbidden, <String, Object?>{
      'error': 'operation disabled during primary certification',
    });
  }

  Future<void> _presentationUnavailable(HttpRequest request) {
    return _respond(request, HttpStatus.serviceUnavailable, <String, Object?>{
      'error': 'presentation surface unavailable',
    });
  }

  /// Times the production local-search DAO queries. Only counts and
  /// durations are returned; no titles or IDs leave the process.
  Future<Map<String, Object?>> _localSearchTiming(String query) async {
    final dao = _container.read(navisDatabaseProvider).libraryDao;
    final stopwatch = Stopwatch()..start();
    final artists = await dao.searchArtistsLocal(query);
    final artistMicros = stopwatch.elapsedMicroseconds;
    stopwatch.reset();
    final albums = await dao.searchAlbumsLocal(query);
    final albumMicros = stopwatch.elapsedMicroseconds;
    stopwatch.reset();
    final songs = await dao.searchSongsLocal(query);
    final songMicros = stopwatch.elapsedMicroseconds;
    return <String, Object?>{
      'artists': <String, Object?>{
        'count': artists.length,
        'elapsedMicros': artistMicros,
      },
      'albums': <String, Object?>{
        'count': albums.length,
        'elapsedMicros': albumMicros,
      },
      'songs': <String, Object?>{
        'count': songs.length,
        'elapsedMicros': songMicros,
      },
    };
  }

  Map<String, Object?> _frameWindowJson() {
    final elapsedMs = DateTime.now()
        .difference(_frameWindowStartedAt)
        .inMilliseconds;
    return <String, Object?>{
      'frames': _frameWindowCount,
      'elapsedMs': elapsedMs,
      'framesPerSecond': elapsedMs <= 0
          ? 0
          : double.parse(
              (_frameWindowCount * 1000 / elapsedMs).toStringAsFixed(2),
            ),
    };
  }

  Map<String, Object?> _imageCacheJson() {
    final cache = PaintingBinding.instance.imageCache;
    return <String, Object?>{
      'currentSize': cache.currentSize,
      'currentSizeBytes': cache.currentSizeBytes,
      'liveImageCount': cache.liveImageCount,
      'pendingImageCount': cache.pendingImageCount,
      'maximumSize': cache.maximumSize,
      'maximumSizeBytes': cache.maximumSizeBytes,
    };
  }

  void _recordFrameTimings(List<FrameTiming> timings) {
    _frameWindowCount += timings.length;
    for (final timing in timings) {
      final buildMicros = timing.buildDuration.inMicroseconds;
      final rasterMicros = timing.rasterDuration.inMicroseconds;
      final spanMicros = timing.totalSpan.inMicroseconds;
      final totalMicros = buildMicros + rasterMicros;
      _frameBuildMicros.add(buildMicros);
      _frameRasterMicros.add(rasterMicros);
      _frameSpanMicros.add(spanMicros);
      _frameMicros.add(totalMicros);
      if (totalMicros > 100000) {
        final sync = _container.read(librarySyncControllerProvider);
        _slowFrameSamples.add(<String, Object?>{
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'phase': sync.candidateStatus ?? sync.stage.name,
          'buildMicros': buildMicros,
          'rasterMicros': rasterMicros,
          'spanMicros': spanMicros,
          'totalMicros': totalMicros,
        });
        if (_slowFrameSamples.length > 32) {
          _slowFrameSamples.removeAt(0);
        }
      }
    }
    _trimSamples(_frameMicros);
    _trimSamples(_frameBuildMicros);
    _trimSamples(_frameRasterMicros);
    _trimSamples(_frameSpanMicros);
  }

  Future<void> _runDatabaseCanary() async {
    if (_canaryRunning) return;
    _canaryRunning = true;
    final sync = _container.read(librarySyncControllerProvider);
    final phase = sync.candidateStatus ?? sync.stage.name;
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    var lastEventLoopTickMicros = 0;
    var maximumEventLoopLagMicros = 0;
    final eventLoopTimer = Timer.periodic(const Duration(milliseconds: 50), (
      _,
    ) {
      final tickMicros = stopwatch.elapsedMicroseconds;
      final lagMicros = tickMicros - lastEventLoopTickMicros - 50000;
      if (lagMicros > maximumEventLoopLagMicros) {
        maximumEventLoopLagMicros = lagMicros;
      }
      lastEventLoopTickMicros = tickMicros;
    });
    try {
      await _container.read(navisDatabaseProvider).libraryDao.countArtists();
      final elapsed = stopwatch.elapsedMicroseconds;
      if (elapsed > 100000) {
        final finalLagMicros = elapsed - lastEventLoopTickMicros - 50000;
        if (finalLagMicros > maximumEventLoopLagMicros) {
          maximumEventLoopLagMicros = finalLagMicros;
        }
        _slowDatabaseCanarySamples.add(<String, Object?>{
          'startedAt': startedAt.toIso8601String(),
          'phase': phase,
          'elapsedMicros': elapsed,
          'eventLoopLagMicros': maximumEventLoopLagMicros,
        });
        if (_slowDatabaseCanarySamples.length > 32) {
          _slowDatabaseCanarySamples.removeAt(0);
        }
      }
      _databaseCanaryMicros.add(elapsed);
      _trimSamples(_databaseCanaryMicros);
      final phaseSamples = _databaseCanaryMicrosByPhase.putIfAbsent(
        phase,
        () => <int>[],
      );
      phaseSamples.add(elapsed);
      _trimSamples(phaseSamples);
    } finally {
      eventLoopTimer.cancel();
      _canaryRunning = false;
    }
  }

  Map<String, Object?> _sampleSummary(List<int> values) {
    if (values.isEmpty) {
      return const <String, Object?>{'samples': 0};
    }
    final sorted = List<int>.of(values)..sort();
    int percentile(double value) {
      final index = ((sorted.length - 1) * value).round();
      return sorted[index];
    }

    return <String, Object?>{
      'samples': sorted.length,
      'p50Micros': percentile(0.5),
      'p95Micros': percentile(0.95),
      'p99Micros': percentile(0.99),
      'maxMicros': sorted.last,
      'over16ms': sorted.where((value) => value > 16667).length,
      'over33ms': sorted.where((value) => value > 33333).length,
    };
  }

  void _startHeartbeat() {
    if (_heartbeatEnabled) return;
    _heartbeatEnabled = true;
    _heartbeatWatch
      ..reset()
      ..start();
    _heartbeatLastTickMicros = 0;
    _heartbeatLastLagMicros = 0;
    // A persistent frame callback that requests the next frame, rather than
    // a Ticker: presentation waits treat running tickers as animations and
    // would never see the UI settle.
    if (!_heartbeatCallbackRegistered) {
      _heartbeatCallbackRegistered = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) {
        if (!_heartbeatEnabled) return;
        final now = _heartbeatWatch.elapsedMicroseconds;
        _heartbeatGapMicros.add(now - _heartbeatLastTickMicros);
        _heartbeatLastTickMicros = now;
        _trimSamples(_heartbeatGapMicros);
        SchedulerBinding.instance.scheduleFrame();
      });
    }
    SchedulerBinding.instance.scheduleFrame();
    const interval = Duration(milliseconds: 8);
    _heartbeatLagTimer = Timer.periodic(interval, (_) {
      final now = _heartbeatWatch.elapsedMicroseconds;
      final lag = now - _heartbeatLastLagMicros - interval.inMicroseconds;
      _eventLoopLagMicros.add(lag < 0 ? 0 : lag);
      _heartbeatLastLagMicros = now;
      _trimSamples(_eventLoopLagMicros);
    });
  }

  void _stopHeartbeat() {
    _heartbeatEnabled = false;
    _heartbeatLagTimer?.cancel();
    _heartbeatLagTimer = null;
    _heartbeatWatch.stop();
  }

  Map<String, Object?> _gapSummary(List<int> values) {
    if (values.isEmpty) {
      return const <String, Object?>{'samples': 0};
    }
    final sorted = List<int>.of(values)..sort();
    int percentile(double value) =>
        sorted[((sorted.length - 1) * value).round()];
    return <String, Object?>{
      'samples': sorted.length,
      'p50Micros': percentile(0.5),
      'p99Micros': percentile(0.99),
      'maxMicros': sorted.last,
      'over50ms': sorted.where((value) => value > 50000).length,
      'over250ms': sorted.where((value) => value > 250000).length,
      'over1000ms': sorted.where((value) => value > 1000000).length,
    };
  }

  Map<String, Object?> _playbackCounters() {
    final counters = _container
        .read(audioHandlerProvider)
        ?.collectPlaybackDiagnostics()['counters'];
    return counters is Map<String, Object?>
        ? counters
        : const <String, Object?>{};
  }

  Map<String, Object?> _playbackCounterDelta() {
    final current = _playbackCounters();
    return <String, Object?>{
      for (final entry in current.entries)
        entry.key: switch (entry.value) {
          final int value =>
            value - ((_playbackCounterBaseline[entry.key] as int?) ?? 0),
          final other => other,
        },
    };
  }

  void _trimSamples(List<int> values) {
    if (values.length > 5000) {
      values.removeRange(0, values.length - 5000);
    }
  }

  Future<void> _writeHandshake(int port) async {
    final handshake = <String, Object?>{
      'port': port,
      'token': _token,
      'pid': pid,
      'mode': mode.name,
    };
    final androidPublisher = androidHandshakePublisher;
    if (androidPublisher != null) {
      await androidPublisher(handshake);
      return;
    }
    final file = File(handshakePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(handshake), flush: true);
    // Windows has no POSIX chmod executable. More importantly, diagnostics
    // must begin serving after the handshake is written; awaiting a missing
    // Unix command here bound the loopback port without ever starting its
    // request loop on Windows.
    if (!Platform.isWindows) {
      await Process.run('chmod', <String>['600', file.path]);
    }
  }
}

abstract interface class DiagnosticsNavigationDriver {
  String get location;

  /// Whether [location] matches an app route.
  bool resolves(String location);

  void go(String location);
}

class ProviderDiagnosticsNavigationDriver
    implements DiagnosticsNavigationDriver {
  const new(this._router);

  final GoRouter Function() _router;

  @override
  String get location => _router().state.uri.toString();

  @override
  bool resolves(String location) {
    final match = _router().configuration.findMatch(Uri.parse(location));
    return !match.isError && match.isNotEmpty;
  }

  @override
  void go(String location) => _router().go(location);
}

bool _isValidDiagnosticsLocation(String value) {
  if (value.isEmpty || value.length > 512) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.path.startsWith('/') &&
      !uri.hasScheme &&
      !uri.hasAuthority;
}

/// Decodes the Library section of a diagnostics location:
/// `/library?section=liked`, or the older `/library#liked` form.
LibrarySection? _librarySectionForDiagnosticsLocation(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.path != AppRoutes.library) {
    return null;
  }
  final fromQuery = NavService.librarySectionForLocation(uri);
  if (fromQuery != null || uri.fragment.isEmpty) {
    return fromQuery;
  }
  for (final section in LibrarySection.values) {
    if (section.name == uri.fragment) {
      return section;
    }
  }
  return null;
}

bool canResumeDiagnosticsPlayback({
  required PlaybackSnapshot snapshot,
  required String songId,
}) {
  return snapshot.hasActivePlayback && snapshot.currentSongId == songId;
}
