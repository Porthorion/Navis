import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';

typedef LibrarySyncProgressCallback = void Function(LibrarySyncState state);

/// Thrown when a sync operation is cancelled via [DriftLibrarySyncEngine.cancelSync].
class SyncCancelledException implements Exception {
  const SyncCancelledException();
  @override
  String toString() => 'SyncCancelledException: sync was cancelled.';
}

class LibrarySyncEngine {
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    throw UnimplementedError('Override syncIfStale in a concrete engine.');
  }

  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    throw UnimplementedError('Override syncNow in a concrete engine.');
  }
}

abstract class LibrarySyncApi {
  Future<List<Artist>> getArtists();
  Future<Artist> getArtist(String id);
  Future<Album> getAlbum(String id);
  Future<StarredContent> getStarredContent();
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  });
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  });
  Future<Indexes> getIndexes({DateTime? ifModifiedSince});
  Future<List<Genre>> getGenres();
  Future<List<Playlist>> getPlaylists();
}

class SubsonicLibrarySyncApi implements LibrarySyncApi {
  const SubsonicLibrarySyncApi(this._api);

  final SubsonicApiClient _api;

  @override
  Future<List<Artist>> getArtists() => _api.getArtists();

  @override
  Future<Artist> getArtist(String id) => _api.getArtist(id);

  @override
  Future<Album> getAlbum(String id) => _api.getAlbum(id);

  @override
  Future<StarredContent> getStarredContent() => _api.getStarred2();

  @override
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  }) {
    return _api.search3(
      query: query,
      artistCount: 0,
      albumCount: 0,
      songCount: size,
      songOffset: offset,
    );
  }

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) {
    return _api.getAlbumList2(
      type: 'alphabeticalByName',
      size: size,
      offset: offset,
    );
  }

  @override
  Future<Indexes> getIndexes({DateTime? ifModifiedSince}) =>
      _api.getIndexes(ifModifiedSince: ifModifiedSince);

  @override
  Future<List<Genre>> getGenres() => _api.getGenres();

  @override
  Future<List<Playlist>> getPlaylists() => _api.getPlaylists();
}

const _navisCapabilitiesNamespace = 'navis';
const _bulkSongSearchQueryCapabilityKey = 'bulkSongSearchWildcardQuery';

int _incrementalArtistFanoutFallbackThreshold({
  required int existingArtistCount,
  required bool hasKnownBulkSongFastPath,
}) {
  final minimumThreshold = hasKnownBulkSongFastPath ? 24 : 48;
  final maximumThreshold = hasKnownBulkSongFastPath ? 128 : 160;
  if (existingArtistCount <= 0) {
    return minimumThreshold;
  }
  final ratioThreshold = (existingArtistCount * 0.1).ceil();
  if (ratioThreshold < minimumThreshold) {
    return minimumThreshold;
  }
  if (ratioThreshold > maximumThreshold) {
    return maximumThreshold;
  }
  return ratioThreshold;
}

bool _shouldFallbackIncrementalArtistFanout({
  required int changedArtistCount,
  required int existingArtistCount,
  required bool hasKnownBulkSongFastPath,
}) {
  if (changedArtistCount <= 0) {
    return false;
  }
  return changedArtistCount >=
      _incrementalArtistFanoutFallbackThreshold(
        existingArtistCount: existingArtistCount,
        hasKnownBulkSongFastPath: hasKnownBulkSongFastPath,
      );
}

String? _readStoredBulkSongSearchQuery(String? capabilitiesJson) {
  if (capabilitiesJson == null || capabilitiesJson.trim().isEmpty) {
    return null;
  }
  try {
    final decoded = jsonDecode(capabilitiesJson);
    if (decoded is! Map) {
      return null;
    }
    final navisCapabilities = decoded[_navisCapabilitiesNamespace];
    if (navisCapabilities is! Map) {
      return null;
    }
    final query = navisCapabilities[_bulkSongSearchQueryCapabilityKey];
    return query is String ? query : null;
  } on FormatException {
    return null;
  }
}

String? _mergeStoredBulkSongSearchQuery(
  String? capabilitiesJson,
  String? query,
) {
  final root = <String, dynamic>{};
  if (capabilitiesJson != null && capabilitiesJson.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(capabilitiesJson);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          root['${entry.key}'] = entry.value;
        }
      }
    } on FormatException {
      root.clear();
    }
  }

  final navisCapabilities = <String, dynamic>{};
  final existingNavisCapabilities = root[_navisCapabilitiesNamespace];
  if (existingNavisCapabilities is Map) {
    for (final entry in existingNavisCapabilities.entries) {
      navisCapabilities['${entry.key}'] = entry.value;
    }
  }

  if (query == null) {
    navisCapabilities.remove(_bulkSongSearchQueryCapabilityKey);
  } else {
    navisCapabilities[_bulkSongSearchQueryCapabilityKey] = query;
  }

  if (navisCapabilities.isEmpty) {
    root.remove(_navisCapabilitiesNamespace);
  } else {
    root[_navisCapabilitiesNamespace] = navisCapabilities;
  }

  if (root.isEmpty) {
    return null;
  }
  return jsonEncode(root);
}

class DriftLibrarySyncEngine implements LibrarySyncEngine {
  DriftLibrarySyncEngine({
    required LibrarySyncApi api,
    required NavisDatabase database,
    required ServerConfigRepository serverConfigRepository,
    this.networkType = NetworkType.other,
    this.staleAfter = const Duration(hours: 1),
    this.rebaselineAfter = const Duration(hours: 24),
    this.fastPathPageSize = 500,
    this.fastPathMaxPages = 200,
    this.bulkSearchPageSize = 1000,
    this.bulkSearchMaxPages = 200,
    this.bulkSearchProbeQueries = const <String>['', '*'],
    this.fallbackArtistConcurrency = 4,
    this.wifiAlbumConcurrency = 8,
    this.cellularAlbumConcurrency = 4,
    this.otherAlbumConcurrency = 6,
    this.wifiMaxAlbumConcurrency = 24,
    this.cellularMaxAlbumConcurrency = 8,
    this.otherMaxAlbumConcurrency = 12,
    this.writeChunkSize = 48,
    this.isolateThreshold = 100,
  }) : _api = api,
       _database = database,
       _serverConfigRepository = serverConfigRepository;

  final LibrarySyncApi _api;
  final NavisDatabase _database;
  final ServerConfigRepository _serverConfigRepository;
  final NetworkType networkType;
  final Duration staleAfter;
  final Duration rebaselineAfter;
  final int fastPathPageSize;
  final int fastPathMaxPages;
  final int bulkSearchPageSize;
  final int bulkSearchMaxPages;
  final List<String> bulkSearchProbeQueries;
  final int fallbackArtistConcurrency;
  final int wifiAlbumConcurrency;
  final int cellularAlbumConcurrency;
  final int otherAlbumConcurrency;
  final int wifiMaxAlbumConcurrency;
  final int cellularMaxAlbumConcurrency;
  final int otherMaxAlbumConcurrency;
  final int writeChunkSize;
  final int isolateThreshold;

  Future<LibrarySyncState>? _inFlight;
  bool _cancelled = false;

  /// Cancel any in-progress sync.  The sync will complete with a `failed`
  /// status and a "Sync cancelled." error message.
  void cancelSync() {
    _cancelled = true;
  }

  /// Throws [SyncCancelledException] if [cancelSync] has been called.
  void _checkCancelled() {
    if (_cancelled) {
      throw const SyncCancelledException();
    }
  }

  int get _albumConcurrency {
    return switch (networkType) {
      NetworkType.wifi => wifiAlbumConcurrency,
      NetworkType.cellular => cellularAlbumConcurrency,
      NetworkType.offline => 2,
      NetworkType.other => otherAlbumConcurrency,
    };
  }

  int get _maxHydrationConcurrency {
    return switch (networkType) {
      NetworkType.wifi => wifiMaxAlbumConcurrency,
      NetworkType.cellular => cellularMaxAlbumConcurrency,
      NetworkType.offline => 2,
      NetworkType.other => otherMaxAlbumConcurrency,
    };
  }

  int get _artistConcurrency {
    final albumConcurrency = _albumConcurrency;
    final tuned = albumConcurrency <= 2
        ? 2
        : albumConcurrency > 6
        ? 6
        : albumConcurrency;
    if (fallbackArtistConcurrency < 1) {
      return tuned;
    }
    return tuned > fallbackArtistConcurrency
        ? fallbackArtistConcurrency
        : tuned;
  }

  @override
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: false,
      forceFull: false,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> syncNow({
    bool forceFull = false,
    bool preferIncremental = false,
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: true,
      forceFull: forceFull,
      preferIncremental: preferIncremental,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  Future<LibrarySyncState> _runWithLock({
    required bool force,
    required bool forceFull,
    bool preferIncremental = false,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) {
    final running = _inFlight;
    if (running != null) {
      return running;
    }

    _cancelled = false;
    final future = _runSync(
      force: force,
      forceFull: forceFull,
      preferIncremental: preferIncremental,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
      _cancelled = false;
    });
  }

  Future<LibrarySyncState> _runSync({
    required bool force,
    required bool forceFull,
    bool preferIncremental = false,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final metrics = _SyncRunMetrics();
    final startedAt = DateTime.now();
    final serverConfig = await _serverConfigRepository.getActiveServer();
    if (serverConfig == null) {
      final failed = _withMetrics(
        LibrarySyncState(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          startedAt: startedAt,
          completedAt: DateTime.now(),
          errorMessage: 'No authenticated server session.',
        ),
        metrics,
      );
      onProgress?.call(failed);
      return failed;
    }

    final mode = _resolveMode(
      serverConfig,
      forceFull: forceFull,
      preferIncremental: preferIncremental,
    );
    final storedBulkSongSearchQuery = _readStoredBulkSongSearchQuery(
      serverConfig.capabilitiesJson,
    );
    var state = _withMetrics(
      LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.preparing,
        startedAt: startedAt,
        mode: mode,
        lastSyncedAt: serverConfig.lastSynced,
      ),
      metrics,
    );
    onProgress?.call(state);

    final now = DateTime.now();
    final hasFreshSync =
        serverConfig.lastSynced != null &&
        now.difference(serverConfig.lastSynced!) < staleAfter;
    final pendingHydrationCount = await _database.libraryDao
        .countPendingHydrationAlbums();

    if (!force && hasFreshSync && pendingHydrationCount == 0) {
      final skipped = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.skipped,
          stage: LibrarySyncStage.completed,
          completedAt: now,
        ),
        metrics,
      );
      onProgress?.call(skipped);
      _logSyncSummary(state: skipped, metrics: metrics);
      return skipped;
    }

    try {
      if (!force && hasFreshSync && pendingHydrationCount > 0) {
        state = await _hydratePendingSongs(
          state: _withMetrics(
            state.copyWith(
              metadataReady: true,
              pendingHydrationCount: pendingHydrationCount,
              hydratedAlbums: 0,
            ),
            metrics,
          ),
          priorityAlbumIds: priorityAlbumIds,
          serverCapabilitiesJson: serverConfig.capabilitiesJson,
          storedBulkSongSearchQuery: storedBulkSongSearchQuery,
          excludedAlbumIds: const <String>{},
          metrics: metrics,
          onProgress: onProgress,
        );
      } else if (mode == LibrarySyncMode.incremental) {
        state = await _runIncrementalSync(
          state: state,
          serverConfig: serverConfig,
          priorityAlbumIds: priorityAlbumIds,
          metrics: metrics,
          onProgress: onProgress,
        );
      } else if (mode == LibrarySyncMode.rebaselineFull) {
        state = await _runRebaselineSync(
          state: state,
          serverConfig: serverConfig,
          priorityAlbumIds: priorityAlbumIds,
          metrics: metrics,
          onProgress: onProgress,
        );
      } else {
        state = await _runFullSync(
          state: state,
          serverConfig: serverConfig,
          mode: mode,
          priorityAlbumIds: priorityAlbumIds,
          metrics: metrics,
          onProgress: onProgress,
        );
      }

      await _reconcileStarredContent(metrics);

      final syncedAt = DateTime.now();
      final completedMode = state.mode ?? mode;
      if (completedMode == LibrarySyncMode.incremental) {
        await _serverConfigRepository.updateLastSynced(syncedAt);
        metrics.addDbWriteBatch();
      } else {
        await _serverConfigRepository.updateSyncTimestamps(
          lastSynced: syncedAt,
          lastFullSyncedAt: syncedAt,
        );
        metrics.addDbWriteBatch();
      }

      final succeeded = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: syncedAt,
          lastSyncedAt: syncedAt,
        ),
        metrics,
      );
      onProgress?.call(succeeded);
      _logSyncSummary(state: succeeded, metrics: metrics);
      return succeeded;
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Library sync failed at stage=${state.stage} mode=${state.mode}.',
        error,
        stackTrace,
      );

      if (_isTransient(error)) {
        final skipped = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.skipped,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            errorMessage:
                'Server temporarily unavailable. Sync will retry later.',
          ),
          metrics,
        );
        onProgress?.call(skipped);
        _logSyncSummary(state: skipped, metrics: metrics);
        return skipped;
      }

      final failed = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: _toSafeErrorMessage(error),
        ),
        metrics,
      );
      onProgress?.call(failed);
      _logSyncSummary(state: failed, metrics: metrics);
      return failed;
    }
  }

  Future<void> _reconcileStarredContent(_SyncRunMetrics metrics) async {
    try {
      final starred = await _api.getStarredContent();
      final pendingActions = await _database.starSyncDao.getPendingActions();
      final pendingByType = <String, Set<String>>{
        'album': <String>{},
        'artist': <String>{},
        'song': <String>{},
      };
      for (final action in pendingActions) {
        pendingByType[action.itemType]?.add(action.itemId);
      }

      final albumStarredAt = <String, DateTime?>{
        for (final album in starred.albums) album.id: album.starred,
      };
      final artistStarredAt = <String, DateTime?>{
        for (final artist in starred.artists) artist.id: artist.starred,
      };
      final songStarredAt = <String, DateTime?>{
        for (final song in starred.songs) song.id: song.starred,
      };

      // Use batch reconciliation — a single transaction per entity type
      // instead of O(n) individual UPDATE statements.
      await _database.libraryDao.batchReconcileAlbumStarred(
        albumStarredAt,
        excludeIds: pendingByType['album']!,
      );
      await _database.libraryDao.batchReconcileArtistStarred(
        artistStarredAt,
        excludeIds: pendingByType['artist']!,
      );
      await _database.libraryDao.batchReconcileSongStarred(
        songStarredAt,
        excludeIds: pendingByType['song']!,
      );

      metrics.addDbWriteBatch();
    } on SubsonicNotFoundException {
      AppLogger.debug(
        'Starred content reconciliation skipped: endpoint unsupported.',
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Starred content reconciliation failed: $error\n$stackTrace',
      );
    }
  }

  LibrarySyncMode _resolveMode(
    ServerConfigModel config, {
    required bool forceFull,
    bool preferIncremental = false,
  }) {
    if (forceFull) {
      return LibrarySyncMode.forceFull;
    }

    if (config.lastSynced == null) {
      return LibrarySyncMode.fullInitial;
    }

    // When preferIncremental is set (e.g. manual pull-to-refresh), skip the
    // rebaseline check and go straight to incremental sync.  This avoids
    // re-fetching the entire library on every manual refresh.
    if (preferIncremental) {
      return LibrarySyncMode.incremental;
    }

    final lastFullSync = config.lastFullSyncedAt;
    if (lastFullSync == null ||
        DateTime.now().difference(lastFullSync) >= rebaselineAfter) {
      return LibrarySyncMode.rebaselineFull;
    }

    return LibrarySyncMode.incremental;
  }

  Future<LibrarySyncState> _runFullSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required LibrarySyncMode mode,
    required Iterable<String> priorityAlbumIds,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingArtists,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    final artists = await _withRetry(_api.getArtists, metrics: metrics);

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.fetchingAlbums,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    List<Album> albums;
    try {
      albums = await _discoverAlbumsFastPath(
        metrics: metrics,
        onPageProgress: ({required discoveredCount, required hasMorePages}) {
          final totalEstimate = hasMorePages
              ? discoveredCount + fastPathPageSize
              : discoveredCount;
          current = _withMetrics(
            current.copyWith(
              processed: discoveredCount,
              total: totalEstimate,
            ),
            metrics,
          );
          onProgress?.call(current);
        },
      );
    } on Object {
      current = _withMetrics(
        current.copyWith(
          processed: 0,
          total: artists.length,
        ),
        metrics,
      );
      onProgress?.call(current);
      final artistDetails = await _mapConcurrent<Artist, Artist>(
        artists,
        _artistConcurrency,
        (artist) async {
          final detail = await _withRetry(
            () => _api.getArtist(artist.id),
            metrics: metrics,
          );
          current = _withMetrics(
            current.copyWith(
              processed: (current.processed ?? 0) + 1,
            ),
            metrics,
          );
          onProgress?.call(current);
          return detail;
        },
      );
      albums = _dedupeAlbums([
        for (final artist in artistDetails) ...artist.albums,
      ]);
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    // Use upsert + stale cleanup instead of destructive replace.  This
    // prevents Drift reactive streams from briefly seeing an empty library
    // between DELETE-all and INSERT-all (which could flash-blank the UI or
    // disrupt the currently-playing song's metadata).
    final nextArtistIds = artists.map((a) => a.id).toSet();
    final nextAlbumIds = albums.map((a) => a.id).toSet();

    await _database.libraryDao.upsertArtists(_toArtistCompanions(artists));
    metrics.addDbWriteBatch();
    await _database.libraryDao.upsertAlbums(
      await _toAlbumCompanions(
        albums,
        pendingHydrationAlbumIds: albums.map((album) => album.id),
      ),
    );
    metrics.addDbWriteBatch();

    // Remove stale artists/albums no longer present on the server.
    final existingArtists = await _database.libraryDao.getAllArtists();
    final staleArtistIds = existingArtists
        .map((a) => a.id)
        .where((id) => !nextArtistIds.contains(id))
        .toList(growable: false);
    for (final staleId in staleArtistIds) {
      await _database.libraryDao.removeArtistTree(staleId);
      metrics.addDbWriteBatch();
    }

    final existingAlbums = await _database.libraryDao.getAllAlbums();
    final staleAlbumIds = existingAlbums
        .map((a) => a.id)
        .where((id) => !nextAlbumIds.contains(id))
        .toList(growable: false);
    if (staleAlbumIds.isNotEmpty) {
      await _database.libraryDao.deleteAlbumsByIds(staleAlbumIds);
      metrics.addDbWriteBatch();
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingGenres),
      metrics,
    );
    onProgress?.call(current);
    final genres = await _withRetry(_api.getGenres, metrics: metrics);
    await _database.libraryDao.replaceGenres(_toGenreCompanions(genres));
    metrics.addDbWriteBatch();

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingPlaylists),
      metrics,
    );
    onProgress?.call(current);
    final playlists = await _withRetry(_api.getPlaylists, metrics: metrics);
    await _database.playlistDao.upsertPlaylists(
      _toPlaylistCompanions(playlists),
    );
    metrics.addDbWriteBatch();

    current = await _hydratePendingSongs(
      state: _withMetrics(
        current.copyWith(
          metadataReady: true,
          pendingHydrationCount: await _database.libraryDao
              .countPendingHydrationAlbums(),
          hydratedAlbums: 0,
        ),
        metrics,
      ),
      priorityAlbumIds: priorityAlbumIds,
      serverCapabilitiesJson: serverConfig.capabilitiesJson,
      storedBulkSongSearchQuery: _readStoredBulkSongSearchQuery(
        serverConfig.capabilitiesJson,
      ),
      excludedAlbumIds: const <String>{},
      metrics: metrics,
      onProgress: onProgress,
    );

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        mode: mode,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);
    return current;
  }

  Future<LibrarySyncState> _runRebaselineSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required Iterable<String> priorityAlbumIds,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingArtists,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    final artists = await _withRetry(_api.getArtists, metrics: metrics);
    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.fetchingAlbums,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    List<Album> albums;
    try {
      albums = await _discoverAlbumsFastPath(
        metrics: metrics,
        onPageProgress: ({required discoveredCount, required hasMorePages}) {
          final totalEstimate = hasMorePages
              ? discoveredCount + fastPathPageSize
              : discoveredCount;
          current = _withMetrics(
            current.copyWith(
              processed: discoveredCount,
              total: totalEstimate,
            ),
            metrics,
          );
          onProgress?.call(current);
        },
      );
    } on Object {
      current = _withMetrics(
        current.copyWith(
          processed: 0,
          total: artists.length,
        ),
        metrics,
      );
      onProgress?.call(current);
      final artistDetails = await _mapConcurrent<Artist, Artist>(
        artists,
        _artistConcurrency,
        (artist) async {
          final detail = await _withRetry(
            () => _api.getArtist(artist.id),
            metrics: metrics,
          );
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
          return detail;
        },
      );
      albums = _dedupeAlbums([
        for (final artist in artistDetails) ...artist.albums,
      ]);
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    final existingArtists = await _database.libraryDao.getAllArtists();
    final existingAlbums = await _database.libraryDao.getAllAlbums();
    final nextArtistIds = artists.map((artist) => artist.id).toSet();
    final nextAlbumsById = <String, Album>{
      for (final album in albums) album.id: album,
    };

    await _database.libraryDao.upsertArtists(_toArtistCompanions(artists));
    metrics.addDbWriteBatch();

    final staleArtistIds = existingArtists
        .map((artist) => artist.id)
        .where((id) => !nextArtistIds.contains(id))
        .toList(growable: false);

    final existingAlbumsById = <String, AlbumsTableData>{
      for (final album in existingAlbums) album.id: album,
    };
    final changedOrNewAlbums = <Album>[];
    final albumsNeedingHydration = <String>[];
    for (final album in albums) {
      final existing = existingAlbumsById[album.id];
      if (existing == null || _albumMetadataChanged(existing, album)) {
        changedOrNewAlbums.add(album);
      }
      if (existing == null || _albumRequiresSongHydration(existing, album)) {
        albumsNeedingHydration.add(album.id);
      }
    }

    if (changedOrNewAlbums.isNotEmpty) {
      await _database.libraryDao.upsertAlbums(
        await _toAlbumCompanions(
          changedOrNewAlbums,
          pendingHydrationAlbumIds: albumsNeedingHydration,
        ),
      );
      metrics.addDbWriteBatch();
    }
    final hydratedWithoutSongRefresh = changedOrNewAlbums
        .map((album) => album.id)
        .where((id) => !albumsNeedingHydration.contains(id))
        .toList(growable: false);
    if (hydratedWithoutSongRefresh.isNotEmpty) {
      await _database.libraryDao.markAlbumsSongsHydratedByIds(
        hydratedWithoutSongRefresh,
      );
      metrics.addDbWriteBatch();
    }
    if (albumsNeedingHydration.isNotEmpty) {
      await _database.libraryDao.markAlbumsPendingHydrationByIds(
        albumsNeedingHydration,
      );
      metrics.addDbWriteBatch();
    }

    final staleAlbumIds = existingAlbums
        .map((album) => album.id)
        .where((id) => !nextAlbumsById.containsKey(id))
        .toList(growable: false);
    if (staleAlbumIds.isNotEmpty) {
      await _database.libraryDao.deleteAlbumsByIds(staleAlbumIds);
      metrics.addDbWriteBatch();
    }

    for (final staleArtistId in staleArtistIds) {
      await _database.libraryDao.removeArtistTree(staleArtistId);
      metrics.addDbWriteBatch();
    }

    current = await _hydratePendingSongs(
      state: _withMetrics(
        current.copyWith(
          metadataReady: true,
          pendingHydrationCount: await _database.libraryDao
              .countPendingHydrationAlbums(),
          hydratedAlbums: 0,
        ),
        metrics,
      ),
      priorityAlbumIds: priorityAlbumIds,
      serverCapabilitiesJson: serverConfig.capabilitiesJson,
      storedBulkSongSearchQuery: _readStoredBulkSongSearchQuery(
        serverConfig.capabilitiesJson,
      ),
      excludedAlbumIds: hydratedWithoutSongRefresh,
      metrics: metrics,
      onProgress: onProgress,
    );

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingGenres),
      metrics,
    );
    onProgress?.call(current);
    final genres = await _withRetry(_api.getGenres, metrics: metrics);
    await _database.libraryDao.replaceGenres(_toGenreCompanions(genres));
    metrics.addDbWriteBatch();

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingPlaylists),
      metrics,
    );
    onProgress?.call(current);
    final playlists = await _withRetry(_api.getPlaylists, metrics: metrics);
    await _database.playlistDao.upsertPlaylists(
      _toPlaylistCompanions(playlists),
    );
    metrics.addDbWriteBatch();

    return _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
  }

  Future<LibrarySyncState> _runIncrementalSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required Iterable<String> priorityAlbumIds,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingArtists,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    Indexes indexes;
    try {
      indexes = await _withRetry(
        () => _api.getIndexes(ifModifiedSince: serverConfig.lastSynced),
        metrics: metrics,
      );
    } on Object catch (error) {
      if (!_isIndexesUnsupported(error)) {
        rethrow;
      }
      return _runRebaselineSync(
        state: current.copyWith(mode: LibrarySyncMode.rebaselineFull),
        serverConfig: serverConfig,
        priorityAlbumIds: priorityAlbumIds,
        metrics: metrics,
        onProgress: onProgress,
      );
    }

    final changedArtistIds = _extractChangedArtistIds(indexes);
    final storedBulkSongSearchQuery = _readStoredBulkSongSearchQuery(
      serverConfig.capabilitiesJson,
    );
    final existingArtistCount = await _database.libraryDao.countArtists();
    if (_shouldFallbackIncrementalArtistFanout(
      changedArtistCount: changedArtistIds.length,
      existingArtistCount: existingArtistCount,
      hasKnownBulkSongFastPath: storedBulkSongSearchQuery != null,
    )) {
      AppLogger.info(
        'Incremental sync fanout too large '
        '(changedArtists=${changedArtistIds.length}, '
        'existingArtists=$existingArtistCount, '
        'knownBulkSongFastPath=${storedBulkSongSearchQuery != null}). '
        'Switching to fast rebaseline sync.',
      );
      return _runRebaselineSync(
        state: current.copyWith(mode: LibrarySyncMode.rebaselineFull),
        serverConfig: serverConfig,
        priorityAlbumIds: priorityAlbumIds,
        metrics: metrics,
        onProgress: onProgress,
      );
    }

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.fetchingAlbums,
        processed: 0,
        total: changedArtistIds.length,
      ),
      metrics,
    );
    onProgress?.call(current);

    final deletedArtistIds = <String>{};
    final details = await _mapConcurrent<String, Artist?>(
      changedArtistIds,
      _artistConcurrency,
      (artistId) async {
        try {
          final artist = await _withRetry(
            () => _api.getArtist(artistId),
            metrics: metrics,
          );
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
          return artist;
        } on SubsonicNotFoundException {
          deletedArtistIds.add(artistId);
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
          return null;
        }
      },
    );

    final artistDetails = details.whereType<Artist>().toList(growable: false);
    final touchedArtistIds = artistDetails.map((artist) => artist.id).toSet();

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    await _database.libraryDao.upsertArtists(
      _toArtistCompanions(artistDetails),
    );
    metrics.addDbWriteBatch();

    final albumsByArtist = <String, List<Album>>{
      for (final artist in artistDetails) artist.id: artist.albums,
    };
    final allAlbums = _dedupeAlbums([
      for (final albums in albumsByArtist.values) ...albums,
    ]);

    // Only mark albums as pending hydration if their metadata actually
    // changed or they are new.  This prevents re-fetching songs 1-by-1 for
    // every album on servers that return all artists from getIndexes
    // regardless of ifModifiedSince.
    final existingAlbumsForChanged = <String, AlbumsTableData>{};
    for (final entry in albumsByArtist.entries) {
      final existing = await _database.libraryDao.getAlbumsByArtist(
        entry.key,
      );
      for (final album in existing) {
        existingAlbumsForChanged[album.id] = album;
      }
    }

    final changedOrNewAlbums = <Album>[];
    final albumsNeedingHydration = <String>[];
    for (final album in allAlbums) {
      final existing = existingAlbumsForChanged[album.id];
      if (existing == null || _albumMetadataChanged(existing, album)) {
        changedOrNewAlbums.add(album);
      }
      if (existing == null || _albumRequiresSongHydration(existing, album)) {
        albumsNeedingHydration.add(album.id);
      }
    }

    if (changedOrNewAlbums.isNotEmpty) {
      await _database.libraryDao.upsertAlbums(
        await _toAlbumCompanions(
          changedOrNewAlbums,
          pendingHydrationAlbumIds: albumsNeedingHydration,
        ),
      );
      metrics.addDbWriteBatch();
    }
    final hydratedWithoutSongRefresh = changedOrNewAlbums
        .map((album) => album.id)
        .where((id) => !albumsNeedingHydration.contains(id))
        .toList(growable: false);
    if (hydratedWithoutSongRefresh.isNotEmpty) {
      await _database.libraryDao.markAlbumsSongsHydratedByIds(
        hydratedWithoutSongRefresh,
      );
      metrics.addDbWriteBatch();
    }
    if (albumsNeedingHydration.isNotEmpty) {
      await _database.libraryDao.markAlbumsPendingHydrationByIds(
        albumsNeedingHydration,
      );
      metrics.addDbWriteBatch();
    }

    for (final entry in albumsByArtist.entries) {
      final nextAlbumIds = entry.value.map((album) => album.id).toSet();
      final existingAlbums = existingAlbumsForChanged.values.where(
        (a) => a.artistId == entry.key,
      );
      final staleAlbumIds = existingAlbums
          .map((album) => album.id)
          .where((id) => !nextAlbumIds.contains(id))
          .toList(growable: false);
      if (staleAlbumIds.isNotEmpty) {
        await _database.libraryDao.deleteAlbumsByIds(staleAlbumIds);
        metrics.addDbWriteBatch();
      }
    }

    for (final deletedArtistId in deletedArtistIds) {
      await _database.libraryDao.removeArtistTree(deletedArtistId);
      metrics.addDbWriteBatch();
    }

    current = await _hydratePendingSongs(
      state: _withMetrics(
        current.copyWith(
          metadataReady: true,
          pendingHydrationCount: await _database.libraryDao
              .countPendingHydrationAlbums(),
          hydratedAlbums: 0,
        ),
        metrics,
      ),
      priorityAlbumIds: priorityAlbumIds,
      serverCapabilitiesJson: serverConfig.capabilitiesJson,
      storedBulkSongSearchQuery: _readStoredBulkSongSearchQuery(
        serverConfig.capabilitiesJson,
      ),
      excludedAlbumIds: hydratedWithoutSongRefresh,
      metrics: metrics,
      onProgress: onProgress,
    );

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingGenres),
      metrics,
    );
    onProgress?.call(current);
    final genres = await _withRetry(_api.getGenres, metrics: metrics);
    await _database.libraryDao.replaceGenres(_toGenreCompanions(genres));
    metrics.addDbWriteBatch();

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingPlaylists),
      metrics,
    );
    onProgress?.call(current);
    final playlists = await _withRetry(_api.getPlaylists, metrics: metrics);
    await _database.playlistDao.upsertPlaylists(
      _toPlaylistCompanions(playlists),
    );
    metrics.addDbWriteBatch();

    return _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        clearProcessed: true,
        clearTotal: true,
        pendingHydrationCount: 0,
        mode: touchedArtistIds.isEmpty
            ? LibrarySyncMode.incremental
            : current.mode,
      ),
      metrics,
    );
  }

  Future<LibrarySyncState> _hydratePendingSongs({
    required LibrarySyncState state,
    required Iterable<String> priorityAlbumIds,
    required String? serverCapabilitiesJson,
    required String? storedBulkSongSearchQuery,
    required Iterable<String> excludedAlbumIds,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final pendingAlbumIds =
        (await _database.libraryDao.getPendingHydrationAlbumIds()).toSet()
          ..removeAll(_normalizeAlbumIds(excludedAlbumIds));
    final pending = pendingAlbumIds.length;
    if (pending == 0) {
      return _withMetrics(
        state.copyWith(
          metadataReady: true,
          isHydrating: false,
          fastPathActive: false,
          hydratedAlbums: 0,
          pendingHydrationCount: 0,
          clearProcessed: true,
          clearTotal: true,
          clearHydrationThroughput: true,
        ),
        metrics,
      );
    }

    final prioritized = _normalizeAlbumIds(
      priorityAlbumIds,
    ).where(pendingAlbumIds.contains).toList(growable: true);
    final validArtistIds = await _database.libraryDao.getArtistIds();
    final expectedSongCounts = await _database.libraryDao
        .getAlbumSongCountsByIds(
          pendingAlbumIds,
        );

    var processed = 0;
    var pendingRemaining = pending;
    final observedBulkAlbumIds = <String>{};
    final hydrationStopwatch = Stopwatch()..start();
    final concurrencyController = _AdaptiveHydrationConcurrency(
      initial: _albumConcurrency,
      min: 2,
      max: _maxHydrationConcurrency,
    );
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingSongs,
        metadataReady: true,
        isHydrating: true,
        fastPathActive: false,
        processed: 0,
        total: pending,
        hydratedAlbums: 0,
        pendingHydrationCount: pending,
      ),
      metrics,
    );
    onProgress?.call(current);

    Future<void> publishProgress(Iterable<String> hydratedAlbumIds) async {
      final hydratedCount = hydratedAlbumIds.length;
      if (hydratedCount == 0) {
        return;
      }
      processed += hydratedCount;
      pendingRemaining -= hydratedCount;
      for (final albumId in hydratedAlbumIds) {
        pendingAlbumIds.remove(albumId);
        prioritized.remove(albumId);
        observedBulkAlbumIds.remove(albumId);
      }
      final throughput = _hydrationThroughput(
        hydratedAlbums: processed,
        elapsed: hydrationStopwatch.elapsed,
      );
      metrics.hydrationThroughputAlbumsPerSecond = throughput;
      current = _withMetrics(
        current.copyWith(
          metadataReady: true,
          isHydrating: true,
          processed: processed,
          total: pending,
          hydratedAlbums: processed,
          pendingHydrationCount: pendingRemaining < 0 ? 0 : pendingRemaining,
          hydrationThroughputAlbumsPerSecond: throughput,
        ),
        metrics,
      );
      onProgress?.call(current);
    }

    void publishBulkObservedProgress(Iterable<String> albumIds) {
      var changed = false;
      for (final albumId in albumIds) {
        if (!pendingAlbumIds.contains(albumId)) {
          continue;
        }
        changed = observedBulkAlbumIds.add(albumId) || changed;
      }
      if (!changed) {
        return;
      }
      final displayProcessed = (processed + observedBulkAlbumIds.length).clamp(
        0,
        pending,
      );
      current = _withMetrics(
        current.copyWith(
          metadataReady: true,
          isHydrating: true,
          processed: displayProcessed,
          total: pending,
          hydratedAlbums: processed,
          pendingHydrationCount: pending - displayProcessed,
        ),
        metrics,
      );
      onProgress?.call(current);
    }

    final bulkQuery = await _probeBulkSongFastPath(
      pendingAlbumIds: pendingAlbumIds,
      preferredQuery: storedBulkSongSearchQuery,
      metrics: metrics,
    );
    if (bulkQuery != null && pendingAlbumIds.isNotEmpty) {
      current = _withMetrics(
        current.copyWith(fastPathActive: true, isHydrating: true),
        metrics,
      );
      onProgress?.call(current);
      try {
        await _hydratePendingSongsWithBulkSearch(
          query: bulkQuery,
          pendingAlbumIds: pendingAlbumIds,
          expectedSongCounts: expectedSongCounts,
          validArtistIds: validArtistIds,
          metrics: metrics,
          onHydratedChunk: publishProgress,
          onObservedChunk: publishBulkObservedProgress,
        );
        final nextCapabilitiesJson = _mergeStoredBulkSongSearchQuery(
          serverCapabilitiesJson,
          bulkQuery,
        );
        if (nextCapabilitiesJson != serverCapabilitiesJson) {
          await _serverConfigRepository.updateCapabilitiesJson(
            nextCapabilitiesJson,
          );
          metrics.addDbWriteBatch();
        }
      } on SyncCancelledException {
        rethrow;
      } on Object catch (error, stackTrace) {
        if (bulkQuery == storedBulkSongSearchQuery) {
          final nextCapabilitiesJson = _mergeStoredBulkSongSearchQuery(
            serverCapabilitiesJson,
            null,
          );
          if (nextCapabilitiesJson != serverCapabilitiesJson) {
            await _serverConfigRepository.updateCapabilitiesJson(
              nextCapabilitiesJson,
            );
            metrics.addDbWriteBatch();
          }
        }
        AppLogger.debug(
          'Bulk song hydration fallback activated due to: $error',
        );
        AppLogger.error(
          'Bulk song hydration encountered an error.',
          error,
          stackTrace,
        );
      } finally {
        current = _withMetrics(
          current.copyWith(fastPathActive: false, isHydrating: true),
          metrics,
        );
        onProgress?.call(current);
      }
    }

    while (pendingAlbumIds.isNotEmpty) {
      _checkCancelled();
      final chunk = await _nextPendingHydrationChunk(
        prioritizedAlbumIds: prioritized,
        limit: writeChunkSize,
      );
      if (chunk.isEmpty) {
        break;
      }

      final details = await _fetchAlbumDetailsAdaptive(
        chunk: chunk,
        concurrencyController: concurrencyController,
        metrics: metrics,
      );

      final songsByAlbum = <String, List<SongsTableCompanion>>{};
      final hydratedAlbumIds = <String>[];
      for (final detail in details) {
        songsByAlbum[detail.id] = await _toSongCompanions(
          detail.songs,
          defaultAlbumId: detail.id,
          validArtistIds: validArtistIds,
        );
        hydratedAlbumIds.add(detail.id);
      }

      await _database.libraryDao.replaceSongsForAlbumsChunk(songsByAlbum);
      metrics.addDbWriteBatch();
      await _database.libraryDao.markAlbumsSongsHydratedByIds(hydratedAlbumIds);
      metrics.addDbWriteBatch();
      await publishProgress(hydratedAlbumIds);
      // Yield to the event loop between write batches so the UI can
      // render frames and respond to user input during long hydrations.
      await Future<void>.delayed(Duration.zero);
    }

    return _withMetrics(
      current.copyWith(
        metadataReady: true,
        isHydrating: false,
        fastPathActive: false,
        pendingHydrationCount: 0,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
  }

  List<String> _normalizeAlbumIds(Iterable<String> ids) {
    return ids
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Future<List<AlbumsTableData>> _nextPendingHydrationChunk({
    required List<String> prioritizedAlbumIds,
    required int limit,
  }) async {
    if (prioritizedAlbumIds.isNotEmpty) {
      final prioritizedChunk = await _database.libraryDao
          .getPendingHydrationAlbumsByIds(
            prioritizedAlbumIds,
            limit: limit,
          );
      if (prioritizedChunk.isNotEmpty) {
        return prioritizedChunk;
      }
    }
    return _database.libraryDao.getPendingHydrationAlbums(limit: limit);
  }

  Future<String?> _probeBulkSongFastPath({
    required Set<String> pendingAlbumIds,
    required String? preferredQuery,
    required _SyncRunMetrics metrics,
  }) async {
    if (preferredQuery == null && pendingAlbumIds.length < writeChunkSize * 2) {
      return null;
    }
    final candidateQueries = <String>[];
    if (preferredQuery != null) {
      candidateQueries.add(preferredQuery);
    }
    for (final query in bulkSearchProbeQueries) {
      if (candidateQueries.contains(query)) {
        continue;
      }
      candidateQueries.add(query);
    }
    for (final query in candidateQueries) {
      try {
        final page = await _withRetry(
          () => _api.searchSongsPage(
            query: query,
            size: 1,
            offset: 0,
          ),
          metrics: metrics,
          maxAttempts: 2,
        );
        if (page.songs.isEmpty) {
          continue;
        }
        final hasAlbumIds = page.songs.any(
          (song) => (song.albumId ?? '').trim().isNotEmpty,
        );
        if (!hasAlbumIds) {
          continue;
        }
        return query;
      } on Object catch (error) {
        AppLogger.debug(
          'Bulk song probe query "$query" unavailable: $error',
        );
      }
    }
    return null;
  }

  Future<void> _hydratePendingSongsWithBulkSearch({
    required String query,
    required Set<String> pendingAlbumIds,
    required Map<String, int?> expectedSongCounts,
    required Set<String> validArtistIds,
    required _SyncRunMetrics metrics,
    required Future<void> Function(Iterable<String> hydratedAlbumIds)
    onHydratedChunk,
    required void Function(Iterable<String> observedAlbumIds) onObservedChunk,
  }) async {
    var offset = 0;
    var pageCount = 0;
    String? lastPageSignature;
    final importedSongCountsByAlbum = <String, int>{};

    Future<void> markHydrated(Iterable<String> albumIds) async {
      final ids = albumIds.toSet().toList(growable: false);
      if (ids.isEmpty) {
        return;
      }
      await _database.libraryDao.markAlbumsSongsHydratedByIds(ids);
      metrics.addDbWriteBatch();
      await onHydratedChunk(ids);
    }

    await markHydrated(
      _collectHydratedAlbumIds(
        candidateAlbumIds: pendingAlbumIds,
        pendingAlbumIds: pendingAlbumIds,
        expectedSongCounts: expectedSongCounts,
        importedSongCountsByAlbum: importedSongCountsByAlbum,
      ),
    );

    while (pendingAlbumIds.isNotEmpty) {
      pageCount++;
      if (pageCount > bulkSearchMaxPages) {
        break;
      }

      final page = await _withRetry(
        () => _api.searchSongsPage(
          query: query,
          size: bulkSearchPageSize,
          offset: offset,
        ),
        metrics: metrics,
        maxAttempts: 3,
      );

      final songs = page.songs;
      if (songs.isEmpty) {
        break;
      }

      final signature = '${songs.first.id}:${songs.last.id}:${songs.length}';
      if (signature == lastPageSignature) {
        break;
      }
      lastPageSignature = signature;

      final rawSongsByAlbum = <String, List<Song>>{};
      for (final song in songs) {
        final albumId = (song.albumId ?? '').trim();
        if (albumId.isEmpty || !pendingAlbumIds.contains(albumId)) {
          continue;
        }
        rawSongsByAlbum.putIfAbsent(albumId, () => <Song>[]).add(song);
      }

      if (rawSongsByAlbum.isNotEmpty) {
        onObservedChunk(rawSongsByAlbum.keys);
        final chunkSongs = <SongsTableCompanion>[];
        for (final entry in rawSongsByAlbum.entries) {
          final companions = await _toSongCompanions(
            entry.value,
            defaultAlbumId: entry.key,
            validArtistIds: validArtistIds,
          );
          chunkSongs.addAll(companions);
          importedSongCountsByAlbum.update(
            entry.key,
            (count) => count + companions.length,
            ifAbsent: () => companions.length,
          );
        }
        // Break upserts into 200-song sub-batches so the DB connection is
        // released between batches and playback reads can interleave.
        const _kSongSubBatchSize = 200;
        for (var i = 0; i < chunkSongs.length; i += _kSongSubBatchSize) {
          final subBatch = chunkSongs.sublist(
            i,
            (i + _kSongSubBatchSize).clamp(0, chunkSongs.length),
          );
          await _database.libraryDao.upsertSongs(subBatch);
          metrics.addDbWriteBatch();
          if (i + _kSongSubBatchSize < chunkSongs.length) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        await markHydrated(
          _collectHydratedAlbumIds(
            candidateAlbumIds: rawSongsByAlbum.keys,
            pendingAlbumIds: pendingAlbumIds,
            expectedSongCounts: expectedSongCounts,
            importedSongCountsByAlbum: importedSongCountsByAlbum,
          ),
        );
      }

      if (songs.length < bulkSearchPageSize) {
        break;
      }
      offset += bulkSearchPageSize;
      // Yield between bulk search pages for UI responsiveness.
      await Future<void>.delayed(Duration.zero);
    }

    if (importedSongCountsByAlbum.isEmpty) {
      return;
    }

    await markHydrated(
      _collectHydratedAlbumIds(
        candidateAlbumIds: pendingAlbumIds,
        pendingAlbumIds: pendingAlbumIds,
        expectedSongCounts: expectedSongCounts,
        importedSongCountsByAlbum: importedSongCountsByAlbum,
      ),
    );
  }

  List<String> _collectHydratedAlbumIds({
    required Iterable<String> candidateAlbumIds,
    required Set<String> pendingAlbumIds,
    required Map<String, int?> expectedSongCounts,
    required Map<String, int> importedSongCountsByAlbum,
  }) {
    final hydrated = <String>[];
    for (final albumId in candidateAlbumIds) {
      if (!pendingAlbumIds.contains(albumId)) {
        continue;
      }
      final expected = expectedSongCounts[albumId];
      if (expected == null) {
        continue;
      }
      if (expected <= 0) {
        hydrated.add(albumId);
        continue;
      }
      final imported = importedSongCountsByAlbum[albumId] ?? 0;
      if (imported >= expected) {
        hydrated.add(albumId);
      }
    }
    return hydrated;
  }

  Future<List<Album>> _discoverAlbumsFastPath({
    required _SyncRunMetrics metrics,
    void Function({
      required int discoveredCount,
      required bool hasMorePages,
    })?
    onPageProgress,
  }) async {
    final byId = <String, Album>{};
    var offset = 0;
    var pageCount = 0;

    while (true) {
      pageCount++;
      if (pageCount > fastPathMaxPages) {
        throw StateError('Album fast path exceeded page limit.');
      }

      final page = await _withRetry(
        () => _api.getAlbumListPage(size: fastPathPageSize, offset: offset),
        metrics: metrics,
      );
      if (page.isEmpty) {
        break;
      }

      for (final album in page) {
        byId[album.id] = album;
      }

      final hasMorePages = page.length >= fastPathPageSize;
      onPageProgress?.call(
        discoveredCount: byId.length,
        hasMorePages: hasMorePages,
      );

      if (!hasMorePages) {
        break;
      }
      offset += fastPathPageSize;
    }

    return byId.values.toList(growable: false);
  }

  Set<String> _extractChangedArtistIds(Indexes indexes) {
    final ids = <String>{};
    for (final index in indexes.indexes) {
      for (final artist in index.artists) {
        ids.add(artist.id);
      }
    }
    for (final artist in indexes.shortcut) {
      ids.add(artist.id);
    }
    for (final artist in indexes.child) {
      ids.add(artist.id);
    }
    return ids;
  }

  List<Album> _dedupeAlbums(List<Album> albums) {
    final map = <String, Album>{};
    for (final album in albums) {
      map[album.id] = album;
    }
    return map.values.toList(growable: false);
  }

  bool _isIndexesUnsupported(Object error) {
    if (error is SubsonicNotFoundException) {
      return true;
    }
    if (error is SubsonicGenericException) {
      return error.code == 404 || error.code == 501;
    }
    return false;
  }

  Future<T> _withRetry<T>(
    Future<T> Function() action, {
    required _SyncRunMetrics metrics,
    int maxAttempts = 4,
  }) async {
    var attempt = 0;
    while (true) {
      _checkCancelled();
      attempt++;
      final stopwatch = Stopwatch()..start();
      try {
        final result = await action();
        metrics.recordApiAttempt(
          elapsed: stopwatch.elapsed,
          isRetryAttempt: attempt > 1,
        );
        return result;
      } on SyncCancelledException {
        rethrow;
      } on Object catch (error) {
        metrics.recordApiAttempt(
          elapsed: stopwatch.elapsed,
          isRetryAttempt: attempt > 1,
        );
        if (!_isTransient(error) || attempt >= maxAttempts) {
          metrics.recordApiFailure();
          rethrow;
        }
        final delay = Duration(milliseconds: 250 * (1 << (attempt - 1)));
        await Future<void>.delayed(delay);
      }
    }
  }

  bool _isTransient(Object error) {
    if (error is SubsonicConnectionException) {
      return true;
    }
    if (error is SubsonicGenericException) {
      final code = error.code;
      if (code == null) {
        return false;
      }
      if (code == 429) {
        return true;
      }
      return code >= 500 && code < 600;
    }
    // Treat socket-level and timeout errors as transient so a single slow
    // response doesn't abort the entire sync.
    if (error is TimeoutException || error is SocketException) {
      return true;
    }
    return false;
  }

  Future<List<Album>> _fetchAlbumDetailsAdaptive({
    required List<AlbumsTableData> chunk,
    required _AdaptiveHydrationConcurrency concurrencyController,
    required _SyncRunMetrics metrics,
  }) async {
    final details = <Album>[];
    var offset = 0;

    while (offset < chunk.length) {
      final batchSize = concurrencyController.current;
      final end = (offset + batchSize) > chunk.length
          ? chunk.length
          : offset + batchSize;
      final batch = chunk.sublist(offset, end);
      offset = end;

      final retriesBefore = metrics.apiRetries;
      final batchStopwatch = Stopwatch()..start();
      final results = await Future.wait(
        batch.map(
          (album) => _withRetry(
            () => _api.getAlbum(album.id),
            metrics: metrics,
          ),
        ),
      );
      batchStopwatch.stop();

      details.addAll(results);
      final avgLatencyMs = results.isEmpty
          ? 0
          : (batchStopwatch.elapsedMilliseconds ~/ results.length);
      concurrencyController.observeBatch(
        averageLatencyMs: avgLatencyMs,
        hadTransientRetries: metrics.apiRetries > retriesBefore,
      );
    }

    return details;
  }

  LibrarySyncState _withMetrics(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
  ) {
    return state.copyWith(
      apiRequests: metrics.apiRequests,
      apiRetries: metrics.apiRetries,
      apiFailures: metrics.apiFailures,
      averageLatencyMs: metrics.averageLatencyMs,
      dbWriteBatches: metrics.dbWriteBatches,
      hydrationThroughputAlbumsPerSecond:
          state.hydrationThroughputAlbumsPerSecond ??
          metrics.hydrationThroughputAlbumsPerSecond,
    );
  }

  double _hydrationThroughput({
    required int hydratedAlbums,
    required Duration elapsed,
  }) {
    final seconds = elapsed.inMilliseconds / 1000;
    if (seconds <= 0) {
      return 0;
    }
    return hydratedAlbums / seconds;
  }

  bool _albumMetadataChanged(AlbumsTableData current, Album next) {
    return current.name != next.name ||
        current.artistId != next.artistId ||
        current.artistName != next.artist ||
        current.songCount != next.songCount ||
        current.duration != next.duration ||
        current.year != next.year ||
        current.genre != next.genre ||
        current.coverArt != next.coverArt ||
        current.starred != next.starred ||
        current.userRating != next.userRating ||
        current.playCount != next.playCount ||
        !_artistListsEqual(current.artists, next.artists);
  }

  bool _artistListsEqual(List<ArtistRef> a, List<ArtistRef> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].name != b[i].name) return false;
    }
    return true;
  }

  bool _albumRequiresSongHydration(AlbumsTableData current, Album next) {
    return current.name != next.name ||
        current.artistId != next.artistId ||
        current.artistName != next.artist ||
        current.songCount != next.songCount ||
        current.duration != next.duration ||
        current.coverArt != next.coverArt;
  }

  void _logSyncSummary({
    required LibrarySyncState state,
    required _SyncRunMetrics metrics,
  }) {
    final startedAt = state.startedAt;
    final completedAt = state.completedAt;
    final durationMs = (startedAt != null && completedAt != null)
        ? completedAt.difference(startedAt).inMilliseconds
        : null;
    AppLogger.info(
      'Library sync summary: '
      'status=${state.status.name} '
      'mode=${state.mode?.name ?? 'unknown'} '
      'requests=${metrics.apiRequests} '
      'retries=${metrics.apiRetries} '
      'failures=${metrics.apiFailures} '
      'avgLatencyMs=${metrics.averageLatencyMs ?? 0} '
      'dbWriteBatches=${metrics.dbWriteBatches} '
      'hydrationAlbumsPerSecond='
      '${metrics.hydrationThroughputAlbumsPerSecond?.toStringAsFixed(2) ?? '0.00'} '
      'durationMs=${durationMs ?? 0}',
    );
  }

  List<ArtistsTableCompanion> _toArtistCompanions(List<Artist> artists) {
    return artists
        .map(
          (artist) => ArtistsTableCompanion.insert(
            id: artist.id,
            name: artist.name,
            albumCount: Value(artist.albumCount),
            coverArt: Value(artist.coverArt),
            starred: Value(artist.starred),
          ),
        )
        .toList(growable: false);
  }

  Future<List<AlbumsTableCompanion>> _toAlbumCompanions(
    List<Album> albums, {
    Iterable<String> pendingHydrationAlbumIds = const <String>[],
  }) async {
    final payload = albums
        .map((album) => album.toJson())
        .toList(growable: false);
    final rows = payload.length >= isolateThreshold
        ? await _parseAlbumRowsInIsolate(payload)
        : _albumRowsFromJson(payload);
    final pendingHydrationSet = pendingHydrationAlbumIds.toSet();

    return rows
        .map(
          (row) => AlbumsTableCompanion.insert(
            id: row.id,
            name: row.name,
            artistId: Value(row.artistId),
            artistName: Value(row.artistName),
            artists: Value(row.artists),
            songCount: Value(row.songCount),
            duration: Value(row.duration),
            year: Value(row.year),
            genre: Value(row.genre),
            coverArt: Value(row.coverArt),
            songsHydrated: Value(!pendingHydrationSet.contains(row.id)),
            starred: Value(row.starred),
            userRating: Value(row.userRating),
            playCount: Value(row.playCount),
            serverCreatedAt: Value(row.created),
          ),
        )
        .toList(growable: false);
  }

  Future<List<SongsTableCompanion>> _toSongCompanions(
    List<Song> songs, {
    String? defaultAlbumId,
    required Set<String> validArtistIds,
  }) async {
    final payload = songs.map((song) => song.toJson()).toList(growable: false);
    final rows = payload.length >= isolateThreshold
        ? await _parseSongRowsInIsolate(payload)
        : _songRowsFromJson(payload);

    return rows
        .map(
          (row) => SongsTableCompanion.insert(
            id: row.id,
            title: row.title,
            albumId: Value(row.albumId ?? defaultAlbumId),
            artistId: Value(
              _sanitizeArtistId(
                artistId: row.artistId,
                validArtistIds: validArtistIds,
              ),
            ),
            artistName: Value(row.artistName),
            albumName: Value(row.albumName),
            track: Value(row.track),
            discNumber: Value(row.discNumber),
            duration: Value(row.duration),
            bitRate: Value(row.bitRate),
            sampleRate: Value(row.sampleRate),
            contentType: Value(row.contentType),
            suffix: Value(row.suffix),
            size: Value(row.size),
            coverArt: Value(row.coverArt),
            starred: Value(row.starred),
            userRating: Value(row.userRating),
            playCount: Value(row.playCount),
            createdAt: Value(row.createdAt),
            replayGainTrackGain: Value(row.replayGainTrackGain),
            replayGainAlbumGain: Value(row.replayGainAlbumGain),
            replayGainTrackPeak: Value(row.replayGainTrackPeak),
            replayGainAlbumPeak: Value(row.replayGainAlbumPeak),
          ),
        )
        .toList(growable: false);
  }

  String? _sanitizeArtistId({
    required String? artistId,
    required Set<String> validArtistIds,
  }) {
    final normalized = artistId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (validArtistIds.contains(normalized)) {
      return normalized;
    }
    return null;
  }

  List<GenresTableCompanion> _toGenreCompanions(List<Genre> genres) {
    if (genres.isEmpty) {
      return const <GenresTableCompanion>[];
    }

    final deduped = <String, Genre>{};
    for (final genre in genres) {
      final name = genre.name.trim();
      if (name.isEmpty) {
        continue;
      }
      final existing = deduped[name];
      if (existing == null) {
        deduped[name] = genre.copyWith(name: name);
        continue;
      }

      deduped[name] = Genre(
        name: name,
        songCount: _maxNullable(existing.songCount, genre.songCount),
        albumCount: _maxNullable(existing.albumCount, genre.albumCount),
      );
    }

    return deduped.values
        .map(
          (genre) => GenresTableCompanion.insert(
            name: genre.name,
            songCount: Value(genre.songCount),
            albumCount: Value(genre.albumCount),
          ),
        )
        .toList(growable: false);
  }

  List<PlaylistsTableCompanion> _toPlaylistCompanions(
    List<Playlist> playlists,
  ) {
    return playlists
        .map(
          (playlist) => PlaylistsTableCompanion.insert(
            id: playlist.id,
            name: playlist.name,
            songCount: Value(playlist.songCount),
            duration: Value(playlist.duration),
            owner: Value(playlist.owner),
            isPublic: Value(playlist.isPublic),
            coverArt: Value(playlist.coverArt),
            comment: Value(playlist.comment),
          ),
        )
        .toList(growable: false);
  }
}

Future<List<R>> _mapConcurrent<T, R>(
  Iterable<T> items,
  int concurrency,
  Future<R> Function(T item) mapper,
) async {
  final itemList = items.toList(growable: false);
  if (itemList.isEmpty) {
    return <R>[];
  }

  final result = List<R?>.filled(itemList.length, null, growable: false);
  var index = 0;

  Future<void> worker() async {
    while (true) {
      final current = index;
      if (current >= itemList.length) {
        return;
      }
      index++;
      result[current] = await mapper(itemList[current]);
    }
  }

  final workerCount = concurrency < 1 ? 1 : concurrency;
  await Future.wait(
    List<Future<void>>.generate(workerCount, (_) => worker()),
  );

  return result.cast<R>();
}

class _SyncRunMetrics {
  int apiRequests = 0;
  int apiRetries = 0;
  int apiFailures = 0;
  int dbWriteBatches = 0;
  int _latencySumMs = 0;
  int _latencySamples = 0;
  double? hydrationThroughputAlbumsPerSecond;

  int? get averageLatencyMs {
    if (_latencySamples == 0) {
      return null;
    }
    return (_latencySumMs / _latencySamples).round();
  }

  void recordApiAttempt({
    required Duration elapsed,
    required bool isRetryAttempt,
  }) {
    apiRequests++;
    if (isRetryAttempt) {
      apiRetries++;
    }
    _latencySumMs += elapsed.inMilliseconds;
    _latencySamples++;
  }

  void recordApiFailure() {
    apiFailures++;
  }

  void addDbWriteBatch() {
    dbWriteBatches++;
  }
}

class _AdaptiveHydrationConcurrency {
  _AdaptiveHydrationConcurrency({
    required int initial,
    required int min,
    required int max,
  }) : _min = min < 1 ? 1 : min,
       _max = max < 1 ? 1 : max,
       _current = initial < min
           ? min
           : initial > max
           ? max
           : initial;

  final int _min;
  final int _max;
  int _current;

  int get current => _current;

  void observeBatch({
    required int averageLatencyMs,
    required bool hadTransientRetries,
  }) {
    if (hadTransientRetries) {
      _decrease(by: 2);
      return;
    }
    if (averageLatencyMs <= 0) {
      return;
    }
    if (averageLatencyMs >= 1800) {
      _decrease(by: 2);
      return;
    }
    if (averageLatencyMs >= 1200) {
      _decrease(by: 1);
      return;
    }
    if (averageLatencyMs <= 450) {
      _increase(by: 2);
      return;
    }
    if (averageLatencyMs <= 800) {
      _increase(by: 1);
    }
  }

  void _increase({required int by}) {
    final next = _current + by;
    _current = next > _max ? _max : next;
  }

  void _decrease({required int by}) {
    final next = _current - by;
    _current = next < _min ? _min : next;
  }
}

class _AlbumRow {
  const _AlbumRow({
    required this.id,
    required this.name,
    this.artistId,
    this.artistName,
    this.artists = const <ArtistRef>[],
    this.songCount,
    this.duration,
    this.year,
    this.genre,
    this.coverArt,
    this.starred,
    this.userRating,
    this.playCount,
    this.created,
  });

  final String id;
  final String name;
  final String? artistId;
  final String? artistName;

  /// OpenSubsonic multi-artist list. Empty on standard Subsonic servers.
  final List<ArtistRef> artists;

  final int? songCount;
  final int? duration;
  final int? year;
  final String? genre;
  final String? coverArt;
  final DateTime? starred;
  final int? userRating;
  final int? playCount;

  /// When the album was added to the server library (`created` from the API).
  final DateTime? created;
}

class _SongRow {
  const _SongRow({
    required this.id,
    required this.title,
    this.albumId,
    this.artistId,
    this.artistName,
    this.albumName,
    this.track,
    this.discNumber,
    this.duration,
    this.bitRate,
    this.sampleRate,
    this.contentType,
    this.suffix,
    this.size,
    this.coverArt,
    this.starred,
    this.userRating,
    this.playCount,
    this.createdAt,
    this.replayGainTrackGain,
    this.replayGainAlbumGain,
    this.replayGainTrackPeak,
    this.replayGainAlbumPeak,
  });

  final String id;
  final String title;
  final String? albumId;
  final String? artistId;
  final String? artistName;
  final String? albumName;
  final int? track;
  final int? discNumber;
  final int? duration;
  final int? bitRate;
  final int? sampleRate;
  final String? contentType;
  final String? suffix;
  final int? size;
  final String? coverArt;
  final DateTime? starred;
  final int? userRating;
  final int? playCount;
  final DateTime? createdAt;
  final double? replayGainTrackGain;
  final double? replayGainAlbumGain;
  final double? replayGainTrackPeak;
  final double? replayGainAlbumPeak;
}

Future<List<_AlbumRow>> _parseAlbumRowsInIsolate(
  List<Map<String, dynamic>> payload,
) {
  return Isolate.run(() => _albumRowsFromJson(payload));
}

Future<List<_SongRow>> _parseSongRowsInIsolate(
  List<Map<String, dynamic>> payload,
) {
  return Isolate.run(() => _songRowsFromJson(payload));
}

List<_AlbumRow> _albumRowsFromJson(List<Map<String, dynamic>> payload) {
  return payload
      .map(
        (json) {
          final rawArtists = json['artists'] as List<dynamic>?;
          final artists = rawArtists != null
              ? rawArtists
                    .map(
                      (e) => ArtistRef.fromJson(e as Map<String, dynamic>),
                    )
                    .toList(growable: false)
              : const <ArtistRef>[];
          return _AlbumRow(
            id: json['id'] as String,
            name: json['name'] as String,
            artistId: json['artistId'] as String?,
            artistName: json['artist'] as String?,
            artists: artists,
            songCount: json['songCount'] as int?,
            duration: json['duration'] as int?,
            year: json['year'] as int?,
            genre: json['genre'] as String?,
            coverArt: json['coverArt'] as String?,
            starred: _parseIsoDate(json['starred'] as String?),
            userRating: json['userRating'] as int?,
            playCount: json['playCount'] as int?,
            created: _parseIsoDate(json['created'] as String?),
          );
        },
      )
      .toList(growable: false);
}

List<_SongRow> _songRowsFromJson(List<Map<String, dynamic>> payload) {
  return payload
      .map(
        (json) {
          final rg = json['replayGain'] as Map<String, dynamic>?;
          return _SongRow(
            id: json['id'] as String,
            title: json['title'] as String,
            albumId: json['albumId'] as String?,
            artistId: json['artistId'] as String?,
            artistName: json['artist'] as String?,
            albumName: json['album'] as String?,
            track: json['track'] as int?,
            discNumber: json['discNumber'] as int?,
            duration: json['duration'] as int?,
            bitRate: json['bitRate'] as int?,
            sampleRate: (json['sampleRate'] as num?)?.toInt(),
            contentType: json['contentType'] as String?,
            suffix: json['suffix'] as String?,
            size: json['size'] as int?,
            coverArt: json['coverArt'] as String?,
            starred: _parseIsoDate(json['starred'] as String?),
            userRating: json['userRating'] as int?,
            playCount: json['playCount'] as int?,
            createdAt: _parseIsoDate(json['created'] as String?),
            replayGainTrackGain: (rg?['trackGain'] as num?)?.toDouble(),
            replayGainAlbumGain: (rg?['albumGain'] as num?)?.toDouble(),
            replayGainTrackPeak: (rg?['trackPeak'] as num?)?.toDouble(),
            replayGainAlbumPeak: (rg?['albumPeak'] as num?)?.toDouble(),
          );
        },
      )
      .toList(growable: false);
}

DateTime? _parseIsoDate(String? value) {
  if (value == null || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value);
}

String _toSafeErrorMessage(Object error) {
  return switch (error) {
    SyncCancelledException() => 'Sync cancelled.',
    SubsonicAuthException() => 'Authentication failed while syncing metadata.',
    SubsonicConnectionException() =>
      'Connection failed while syncing metadata. Retrying later may help.',
    SubsonicApiException(:final message) => message,
    _ => 'Metadata sync failed.',
  };
}

int? _maxNullable(int? left, int? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left > right ? left : right;
}
