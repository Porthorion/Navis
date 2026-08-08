import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:navis/src/common_widgets/song_playback_indicator.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/adaptive_library_sync_coordinator.dart';
import 'package:navis/src/features/library/data/library_sync_engine.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/player_sheet_provider.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/routing/app_router.dart';
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
  LibrarySyncState? _activeProgress;
  LibrarySyncState? _lastSync;
  Object? _lastSyncError;
  Map<String, int> _lastEndpointRequests = const <String, int>{};
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
        if (surface != 'queue' || visible is! bool) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': 'surface must be queue and visible must be boolean',
          });
          return;
        }
        final controller = _container.read(
          playerOverlayStackProvider.notifier,
        );
        if (visible) {
          controller.hideQueue();
          await presentation.waitForFrame();
          controller.showQueueOnly();
        } else {
          controller.hideQueue();
        }
        await presentation.waitForFrame();
        final stack = _container.read(playerOverlayStackProvider);
        await _respond(request, HttpStatus.ok, <String, Object?>{
          'surface': 'queue',
          'visible': stack.contains(PlayerOverlayRoute.queue),
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
        await _respond(
          request,
          HttpStatus.ok,
          _syncStateJson(
            _activeProgress ??
                _lastSync ??
                _container.read(librarySyncControllerProvider),
          ),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/search/source-audit') {
        await _runSourceAudit(request);
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
        await _respond(
          request,
          HttpStatus.ok,
          _container.read(syncDiagnosticsOverridesProvider).toJson(),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/automatic') {
        final engine = _container.read(librarySyncEngineProvider);
        if (engine == null) {
          await _syncUnavailable(request);
          return;
        }
        await _startSync(
          request,
          (onProgress) => engine.syncIfStale(onProgress: onProgress),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/check') {
        final engine = _container.read(librarySyncEngineProvider);
        if (engine == null) {
          await _syncUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final allowOverride = body['allowMeteredBroadOverride'] == true;
        await _startSync(
          request,
          (onProgress) => _runCheck(engine, allowOverride, onProgress),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/repair') {
        final engine = _container.read(librarySyncEngineProvider);
        if (engine == null) {
          await _syncUnavailable(request);
          return;
        }
        final body = await _readJson(request);
        final allowOverride = body['allowMeteredBroadOverride'] == true;
        await _startSync(
          request,
          (onProgress) => _runRepair(engine, allowOverride, onProgress),
        );
        return;
      }
      if (request.method == 'POST' && path == '/v1/sync/target') {
        if (!allowsMutations) {
          await _forbidden(request);
          return;
        }
        final engine = _container.read(librarySyncEngineProvider);
        if (engine == null) {
          await _syncUnavailable(request);
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
        await _startSync(
          request,
          (onProgress) => engine.requestSync(
            LibrarySyncRequest(
              trigger: LibrarySyncTrigger.interaction,
              intent: LibrarySyncIntent.checkForUpdates,
              target: target,
            ),
            onProgress: onProgress,
          ),
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

  Future<void> _startSync(
    HttpRequest request,
    Future<LibrarySyncState> Function(
      LibrarySyncProgressCallback onProgress,
    )
    operation,
  ) async {
    if (_activeSync != null) {
      await _respond(request, HttpStatus.conflict, <String, Object?>{
        'error': 'sync already running',
      });
      return;
    }
    _lastSyncError = null;
    _activeProgress = _container.read(librarySyncControllerProvider);
    final future = operation((progress) => _activeProgress = progress);
    _activeSync = future;
    unawaited(
      future
          .then(
            (state) {
              _lastSync = state;
              _captureEndpointRequests();
            },
            onError: (Object error) => _lastSyncError = error,
          )
          .whenComplete(() {
            _activeSync = null;
            _activeProgress = null;
          }),
    );
    await _respond(request, HttpStatus.accepted, <String, Object?>{
      'status': 'started',
    });
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
    final query = (body['query'] as String? ?? '').trim();
    if (query.isEmpty) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': 'query is required',
      });
      return;
    }
    final api = _container.read(subsonicApiProvider);
    if (api == null) {
      await _respond(request, HttpStatus.serviceUnavailable, <String, Object?>{
        'error': 'search unavailable',
      });
      return;
    }

    final result = await api.search3(query: query);
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
      'records': records,
    });
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

  Future<void> _syncUnavailable(HttpRequest request) {
    return _respond(request, HttpStatus.serviceUnavailable, <String, Object?>{
      'error': 'sync unavailable',
    });
  }

  Future<LibrarySyncState> _runCheck(
    LibrarySyncEngine engine,
    bool allowMeteredBroadOverride,
    LibrarySyncProgressCallback onProgress,
  ) {
    if (engine is AdaptiveLibrarySyncCoordinator) {
      return engine.syncNow(
        onProgress: onProgress,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
      );
    }
    return engine.syncNow(onProgress: onProgress);
  }

  Future<LibrarySyncState> _runRepair(
    LibrarySyncEngine engine,
    bool allowMeteredBroadOverride,
    LibrarySyncProgressCallback onProgress,
  ) {
    if (engine is AdaptiveLibrarySyncCoordinator) {
      return engine.forceFullSync(
        onProgress: onProgress,
        allowMeteredBroadOverride: allowMeteredBroadOverride,
      );
    }
    return engine.forceFullSync(onProgress: onProgress);
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
      'sync': _syncStateJson(
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

  Map<String, Object?> _syncStateJson(LibrarySyncState state) {
    final policy = _container.read(syncNetworkPolicyProvider);
    final overrides = _container.read(syncDiagnosticsOverridesProvider);
    final json = <String, Object?>{
      'requestActive': _activeSync != null,
      'status': state.status.name,
      'stage': state.stage.name,
      'mode': state.mode?.name,
      'planKind': state.planKind?.name,
      'planReason': state.planReason,
      'processed': state.processed,
      'total': state.total,
      'pendingWork': state.pendingWorkCount,
      'candidateStatus': state.candidateStatus,
      'candidateGeneration': state.candidateGeneration,
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
    final LibrarySyncState sync =
        _activeProgress ?? _container.read(librarySyncControllerProvider);
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
    await Process.run('chmod', <String>['600', file.path]);
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

bool canResumeDiagnosticsPlayback({
  required PlaybackSnapshot snapshot,
  required String songId,
}) {
  return snapshot.hasActivePlayback && snapshot.currentSongId == songId;
}
