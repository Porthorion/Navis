import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/initial_server_sync_provider.dart';
import 'package:navis/src/features/auth/presentation/server_connection_provider.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/session_route_provider.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/home/presentation/home_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/search/domain/search_result_ranker.dart';
import 'package:navis/src/features/search/presentation/search_controller_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
import 'package:navis/src/routing/desktop_layout.dart';
import 'package:navis/src/routing/desktop_window_controller.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/diagnostics_presentation_controller.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

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
  SyncDiagnosticsServer({
    required ProviderContainer container,
    required this.mode,
    required this.handshakePath,
    required this.onShutdown,
    this.presentationController,
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
  final DiagnosticsNavigationDriver _navigationDriver;
  final Random _random;
  final List<int> _frameMicros = <int>[];
  final List<int> _databaseCanaryMicros = <int>[];
  final Map<String, List<int>> _databaseCanaryMicrosByPhase =
      <String, List<int>>{};
  final DateTime _startedAt = DateTime.now();
  late final String _token;
  HttpServer? _server;
  Timer? _canaryTimer;
  bool _canaryRunning = false;
  Future<LibrarySyncState>? _activeSync;
  LibrarySyncState? _lastSync;
  Object? _lastSyncError;
  Map<String, int> _lastEndpointRequests = const <String, int>{};
  final List<Map<String, Object?>> _syncLedger = <Map<String, Object?>>[];
  int _nextSyncLedgerId = 1;
  Map<String, Song> _presentationSearchSongs = const <String, Song>{};
  StreamSubscription<Object?>? _playbackFailureSubscription;
  int _playbackFailureCount = 0;

  bool get allowsMutations => mode == SyncDiagnosticsMode.clone;

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _token = base64Url.encode(
      List<int>.generate(32, (_) => _random.nextInt(256)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    SchedulerBinding.instance.addTimingsCallback(_recordFrameTimings);
    _canaryTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_runDatabaseCanary()),
    );
    final handler = _container.read(audioHandlerProvider);
    _playbackFailureSubscription = handler?.loadFailureStream.listen((_) {
      _playbackFailureCount++;
    });
    await _writeHandshake(server.port);
    unawaited(_serve(server));
  }

  Future<void> close() async {
    _canaryTimer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_recordFrameTimings);
    await _playbackFailureSubscription?.cancel();
    await _server?.close(force: true);
    _server = null;
    final file = File(handshakePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handle(request));
    }
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
      if (request.method == 'GET' && path == '/v1/presentation/window') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _respond(
          request,
          HttpStatus.ok,
          await _windowPresentationJson(),
        );
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
        await _respond(
          request,
          HttpStatus.ok,
          await _windowPresentationJson(),
        );
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
        _navigationDriver.go(location);
        final librarySection = _librarySectionForDiagnosticsLocation(location);
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
            'error':
                'surface must be queue or nowPlaying and visible must be boolean',
          });
          return;
        }
        final controller = _container.read(
          playerOverlayStackProvider.notifier,
        );
        final route = surface == 'queue'
            ? PlayerOverlayRoute.queue
            : PlayerOverlayRoute.nowPlaying;
        if (surface == 'queue') {
          if (visible) {
            controller.hideQueue();
            await presentation.waitForFrame();
            controller.showQueueOnly();
          } else {
            controller.hideQueue();
          }
        } else if (visible) {
          controller.expand();
        } else {
          controller.collapse();
        }
        await presentation.waitForFrame();
        final stack = _container.read(playerOverlayStackProvider);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'surface': surface,
          'visible': stack.contains(route),
          'stack': stack.map((route) => route.name).toList(growable: false),
        });
        return;
      }
      if (request.method == 'POST' && path == '/v1/presentation/screenshot') {
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
        // The engine updates this map with every progress frame. Refresh it
        // here as well so a long-running repair exposes its live endpoint mix
        // instead of the previous completed run's counts.
        _captureEndpointRequests();
        final controllerState = _container.read(librarySyncControllerProvider);
        await _respond(
          request,
          HttpStatus.ok,
          await _syncStateJson(
            (_activeSync != null ? controllerState : _lastSync) ??
                controllerState,
          ),
        );
        return;
      }
      if (request.method == 'GET' && path == '/v1/sync/ledger') {
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'events': _syncLedger,
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
          },
        });
        return;
      }
      if (request.method == 'GET' && path == '/v1/session/status') {
        await _respond(
          request,
          HttpStatus.ok,
          await _sessionStatusJson(),
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
        await _container
            .read(initialServerSyncControllerProvider.notifier)
            .retry();
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/initial-sync/mobile') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _container
            .read(initialServerSyncControllerProvider.notifier)
            .startUsingMobileData();
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
        return;
      }
      if (request.method == 'POST' &&
          path == '/v1/session/initial-sync/cancel') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        await _container
            .read(initialServerSyncControllerProvider.notifier)
            .cancelAndLogOut();
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
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
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
        await _respond(request, HttpStatus.ok, await _sessionStatusJson());
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
      if (request.method == 'GET' && path == '/v1/playback/volume') {
        await _respond(
          request,
          HttpStatus.ok,
          await _playbackVolumeStatus(),
        );
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
        await _respond(
          request,
          HttpStatus.ok,
          await _playbackVolumeStatus(),
        );
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
        await _respond(
          request,
          HttpStatus.ok,
          await _playbackVolumeStatus(),
        );
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
    final entries = await _container
        .read(navisDatabaseProvider)
        .cacheDao
        .getCachedTracks();
    var missingFiles = 0;
    var rolling = 0;
    var permanent = 0;
    for (final entry in entries) {
      if (!File(entry.filePath).existsSync()) {
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
    };
  }

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
    final controllerSync = _container.read(librarySyncControllerProvider);
    final sync = _activeSync != null
        ? controllerSync
        : _lastSync ?? controllerSync;
    final phase = _container.read(sessionRoutePhaseProvider);
    final initialSync = activateInitialSync
        ? _container.read(initialServerSyncControllerProvider).status
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
              _captureEndpointRequests();
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
      'endpointRequests': state == null ? null : _lastEndpointRequests,
      'errorType': errorType,
    });
    if (_syncLedger.length > 50) {
      _syncLedger.removeRange(0, _syncLedger.length - 50);
    }
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

    _navigationDriver.go('/search');
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
          isExternalCatalogSource(
            id: song.id,
            apiIsExternal: song.isExternal,
          )
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
    final source = classifyCatalogSource(
      id: id,
      apiIsExternal: apiIsExternal,
    );
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
    final source = classifyCatalogSource(
      id: id,
      apiIsExternal: apiIsExternal,
    );
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

  void _captureEndpointRequests() {
    final engine = _container.read(librarySyncEngineProvider);
    DriftLibrarySyncEngine? drift;
    if (engine is DriftLibrarySyncEngine) {
      drift = engine;
    } else if (engine is AdaptiveLibrarySyncCoordinator) {
      drift = engine.driftExecutor;
    }
    if (drift != null) {
      _lastEndpointRequests = Map<String, int>.from(
        drift.lastEndpointRequestCounts,
      );
    }
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
    final dao = _container.read(navisDatabaseProvider).libraryDao;
    if (field == 'starred') {
      final value = body['value'];
      if (value is! bool) throw const FormatException();
      final starred = value ? DateTime.now() : null;
      switch (type) {
        case 'artist':
          await dao.updateArtistStarred(id, starred);
        case 'album':
          await dao.updateAlbumStarred(id, starred);
        case 'song':
          await dao.updateSongStarred(id, starred);
        default:
          throw const FormatException();
      }
      await _container
          .read(navisDatabaseProvider)
          .starSyncDao
          .queueStarAction(
            itemId: id,
            itemType: type,
            action: value ? 'star' : 'unstar',
          );
    } else if (field == 'rating') {
      final value = body['value'];
      if (value != null && value is! int) throw const FormatException();
      switch (type) {
        case 'album':
          await dao.updateAlbumRating(id, value as int?);
        case 'song':
          await dao.updateSongRating(id, value as int?);
        default:
          throw const FormatException();
      }
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
      (action) => action.itemType == 'song' && action.itemId == songId,
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
    return <String, Object?>{
      'mode': mode.name,
      'startedAt': _startedAt.toIso8601String(),
      'capturedAt': DateTime.now().toIso8601String(),
      'rssBytes': ProcessInfo.currentRss,
      'catalog': <String, int>{
        'artists': counts.artists,
        'albums': counts.albums,
        'songs': counts.songs,
      },
      'sync': await _syncStateJson(
        _lastSync ?? _container.read(librarySyncControllerProvider),
      ),
      'syncErrorType': _lastSyncError?.runtimeType.toString(),
      'diagnosticsOverrides': _container
          .read(syncDiagnosticsOverridesProvider)
          .toJson(),
      'endpointRequests': _lastEndpointRequests,
      'promotion': _decodeSafeJson(
        persistedSync?.lastPromotionDiagnosticsJson,
      ),
      'frames': _sampleSummary(_frameMicros),
      'databaseCanary': _sampleSummary(_databaseCanaryMicros),
      'databaseCanaryByPhase': <String, Object?>{
        for (final entry in _databaseCanaryMicrosByPhase.entries)
          entry.key: _sampleSummary(entry.value),
      },
      'playback': <String, Object?>{
        'active': playback?.hasActivePlayback ?? false,
        'playing': playback?.playing ?? false,
        'songId': playback?.currentSongId,
        'loadFailures': _playbackFailureCount,
      },
    };
  }

  Future<Map<String, Object?>> _syncStateJson(LibrarySyncState state) async {
    final policy = _container.read(syncNetworkPolicyProvider);
    final overrides = _container.read(syncDiagnosticsOverridesProvider);
    final catalog = await _container
        .read(navisDatabaseProvider)
        .libraryDao
        .getCatalogCounts();
    final json = <String, Object?>{
      'requestActive': _activeSync != null,
      'status': state.status.name,
      'stage': state.stage.name,
      'mode': state.mode?.name,
      'planKind': state.planKind?.name,
      'planReason': state.planReason,
      'nextAutomaticCheckAt': state.nextAutomaticCheckAt
          ?.toUtc()
          .toIso8601String(),
      'processed': state.processed,
      'total': state.total,
      'hydrationAlbumsPerSecond': state.hydrationThroughputAlbumsPerSecond,
      'pendingWork': state.pendingWorkCount,
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
      'catalog': <String, int>{
        'artists': catalog.artists,
        'albums': catalog.albums,
        'songs': catalog.songs,
      },
    };
    if (overrides.requestReporting) {
      json['endpointRequests'] = _lastEndpointRequests;
    }
    return json;
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

  void _recordFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _frameMicros.add(
        timing.buildDuration.inMicroseconds +
            timing.rasterDuration.inMicroseconds,
      );
    }
    _trimSamples(_frameMicros);
  }

  Future<void> _runDatabaseCanary() async {
    if (_canaryRunning) return;
    _canaryRunning = true;
    final sync = _container.read(librarySyncControllerProvider);
    final phase = sync.candidateStatus ?? sync.stage.name;
    final stopwatch = Stopwatch()..start();
    try {
      await _container.read(navisDatabaseProvider).libraryDao.countArtists();
      final elapsed = stopwatch.elapsedMicroseconds;
      _databaseCanaryMicros.add(elapsed);
      _trimSamples(_databaseCanaryMicros);
      final phaseSamples = _databaseCanaryMicrosByPhase.putIfAbsent(
        phase,
        () => <int>[],
      );
      phaseSamples.add(elapsed);
      _trimSamples(phaseSamples);
    } finally {
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
      'p95Micros': percentile(0.95),
      'p99Micros': percentile(0.99),
      'maxMicros': sorted.last,
    };
  }

  void _trimSamples(List<int> values) {
    if (values.length > 5000) {
      values.removeRange(0, values.length - 5000);
    }
  }

  Future<void> _writeHandshake(int port) async {
    final file = File(handshakePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, Object?>{
        'port': port,
        'token': _token,
        'pid': pid,
        'mode': mode.name,
      }),
      flush: true,
    );
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

  void go(String location);
}

class ProviderDiagnosticsNavigationDriver
    implements DiagnosticsNavigationDriver {
  const ProviderDiagnosticsNavigationDriver(this._router);

  final GoRouter Function() _router;

  @override
  String get location => _router().state.uri.toString();

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

/// Decodes the virtual Library destinations used by desktop navigation
/// history. The diagnostics route uses this so that an app-API navigation to
/// `/library#liked` drives the same section provider as the visible rail.
LibrarySection? _librarySectionForDiagnosticsLocation(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.path != '/library' || uri.fragment.isEmpty) {
    return null;
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
