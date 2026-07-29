import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
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

enum _AlbumFetchOutcome { success, deleted, requeue, hardFailure }

class _AlbumFetchResult {
  const _AlbumFetchResult._(this.outcome, [this.album]);

  const _AlbumFetchResult.success(Album album)
    : this._(_AlbumFetchOutcome.success, album);

  const _AlbumFetchResult.deleted() : this._(_AlbumFetchOutcome.deleted);

  const _AlbumFetchResult.requeue() : this._(_AlbumFetchOutcome.requeue);

  const _AlbumFetchResult.hardFailure()
    : this._(_AlbumFetchOutcome.hardFailure);

  final _AlbumFetchOutcome outcome;
  final Album? album;
}

class _AlbumBatchFetchResult {
  const _AlbumBatchFetchResult({
    required this.albums,
    required this.deletedAlbumIds,
    required this.requeueAlbumIds,
    required this.hardFailedAlbumIds,
  });

  final List<Album> albums;
  final List<String> deletedAlbumIds;
  final List<String> requeueAlbumIds;
  final List<String> hardFailedAlbumIds;
}

class _SyncFailureDiagnostic {
  const _SyncFailureDiagnostic({
    required this.stage,
    required this.endpoint,
    required this.entityId,
    required this.errorType,
    required this.attempts,
  });

  final String stage;
  final String endpoint;
  final String entityId;
  final String errorType;
  final int attempts;

  Map<String, Object> toJson() => <String, Object>{
    'stage': stage,
    'endpoint': endpoint,
    'entityId': entityId,
    'errorType': errorType,
    'attempts': attempts,
  };
}

abstract class LibrarySyncEngine {
  Future<LibrarySyncState> syncIfStale({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });
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
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return getAlbumListPage(size: size, offset: offset);
  }

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
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return _api.getAlbumList2(type: 'newest', size: size, offset: offset);
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
const _libraryIndexesFingerprintCapabilityKey = 'libraryIndexesFingerprint';
const _libraryIndexesCursorCapabilityKey = 'libraryIndexesCursor';
const _libraryPendingFingerprintCapabilityKey =
    'libraryPendingIndexesFingerprint';
const _libraryPendingCursorCapabilityKey = 'libraryPendingIndexesCursor';
const _libraryPendingOffsetCapabilityKey = 'libraryPendingIndexesOffset';
const _libraryPendingArtistIdsCapabilityKey = 'libraryPendingIndexesArtistIds';
const _libraryIndexesUnsupportedAtCapabilityKey = 'libraryIndexesUnsupportedAt';
const _libraryHealthCheckedAtCapabilityKey = 'libraryHealthCheckedAt';
const _libraryFreshnessCapabilityKey = 'libraryFreshness';
const _librarySyncFailureDiagnosticsCapabilityKey =
    'librarySyncFailureDiagnostics';
const _librarySyncFailureRecordedAtCapabilityKey =
    'librarySyncFailureRecordedAt';
const _auxiliarySyncLastSyncedAtCapabilityKey = 'auxiliarySyncLastSyncedAt';
const _defaultAuxiliarySyncStaleAfter = Duration(hours: 12);
const _defaultHealthProbeStaleAfter = Duration(hours: 12);
const _indexesCapabilityRetryAfter = Duration(days: 1);
const _normalArtistVerificationLimit = 48;
const _cellularManualArtistVerificationLimit = 24;
const _newestAlbumHealthProbePageSize = 100;

String? _readStoredBulkSongSearchQuery(String? capabilitiesJson) {
  return _readNavisStringCapability(
    capabilitiesJson,
    _bulkSongSearchQueryCapabilityKey,
  );
}

DateTime? _readStoredAuxiliarySyncedAt(String? capabilitiesJson) {
  final raw = _readNavisStringCapability(
    capabilitiesJson,
    _auxiliarySyncLastSyncedAtCapabilityKey,
  );
  if (raw == null || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}

LibrarySyncFreshness _readStoredLibraryFreshness(String? capabilitiesJson) {
  final value = _readNavisStringCapability(
    capabilitiesJson,
    _libraryFreshnessCapabilityKey,
  );
  return LibrarySyncFreshness.values.firstWhere(
    (freshness) => freshness.name == value,
    orElse: () => LibrarySyncFreshness.verificationPending,
  );
}

DateTime? _readNavisDateCapability(String? capabilitiesJson, String key) {
  final raw = _readNavisStringCapability(capabilitiesJson, key);
  return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
}

int _readNavisIntCapability(
  String? capabilitiesJson,
  String key, {
  int fallback = 0,
}) {
  final raw = _readNavisStringCapability(capabilitiesJson, key);
  return raw == null ? fallback : int.tryParse(raw) ?? fallback;
}

String? _readNavisStringCapability(String? capabilitiesJson, String key) {
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
    final value = navisCapabilities[key];
    return value is String ? value : null;
  } on FormatException {
    return null;
  }
}

String? _mergeStoredBulkSongSearchQuery(
  String? capabilitiesJson,
  String? query,
) {
  return _mergeNavisStringCapability(
    capabilitiesJson,
    _bulkSongSearchQueryCapabilityKey,
    query,
  );
}

String? _mergeStoredIndexesFingerprint(
  String? capabilitiesJson,
  String? fingerprint,
) {
  return _mergeNavisStringCapability(
    capabilitiesJson,
    _libraryIndexesFingerprintCapabilityKey,
    fingerprint,
  );
}

String? _mergeStoredAuxiliarySyncedAt(
  String? capabilitiesJson,
  DateTime? syncedAt,
) {
  return _mergeNavisStringCapability(
    capabilitiesJson,
    _auxiliarySyncLastSyncedAtCapabilityKey,
    syncedAt?.toUtc().toIso8601String(),
  );
}

String? _mergeNavisStringCapability(
  String? capabilitiesJson,
  String key,
  String? value,
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

  if (value == null) {
    navisCapabilities.remove(key);
  } else {
    navisCapabilities[key] = value;
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

String? _mergeNavisCapabilities(
  String? capabilitiesJson,
  Map<String, Object?> changes,
) {
  var merged = capabilitiesJson;
  for (final entry in changes.entries) {
    final value = entry.value;
    merged = _mergeNavisStringCapability(
      merged,
      entry.key,
      switch (value) {
        null => null,
        DateTime() => value.toUtc().toIso8601String(),
        _ => '$value',
      },
    );
  }
  return merged;
}

String _fingerprintIndexes(Indexes indexes) {
  final artistIds = <String>{};
  for (final index in indexes.indexes) {
    for (final artist in index.artists) {
      final id = artist.id.trim();
      if (id.isNotEmpty) {
        artistIds.add(id);
      }
    }
  }
  for (final artist in indexes.shortcut) {
    final id = artist.id.trim();
    if (id.isNotEmpty) {
      artistIds.add(id);
    }
  }
  for (final artist in indexes.child) {
    final id = artist.id.trim();
    if (id.isNotEmpty) {
      artistIds.add(id);
    }
  }
  final normalized = artistIds.toList(growable: false)..sort();
  return sha1.convert(utf8.encode(normalized.join('\n'))).toString();
}

Map<String, Artist> _indexArtistsById(Indexes indexes) {
  final artists = <String, Artist>{};
  for (final group in indexes.indexes) {
    for (final artist in group.artists) {
      final id = artist.id.trim();
      if (id.isNotEmpty) {
        artists[id] = artist;
      }
    }
  }
  for (final artist in <Artist>[...indexes.shortcut, ...indexes.child]) {
    final id = artist.id.trim();
    if (id.isNotEmpty) {
      artists[id] = artist;
    }
  }
  return artists;
}

String _fingerprintArtistIds(Iterable<String> artistIds) {
  final normalized =
      artistIds
          .map((id) => id.trim())
          .where((id) => id.isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  return sha1.convert(utf8.encode(normalized.join('\n'))).toString();
}

List<String> _readPendingArtistIds(String? capabilitiesJson) {
  final raw = _readNavisStringCapability(
    capabilitiesJson,
    _libraryPendingArtistIdsCapabilityKey,
  );
  if (raw == null || raw.isEmpty) {
    return const <String>[];
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <String>[];
    }
    return decoded
        .whereType<String>()
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  } on FormatException {
    return const <String>[];
  }
}

List<String> _dedupeArtistIds(Iterable<Iterable<String>> groups) {
  final ids = <String>[];
  final seen = <String>{};
  for (final group in groups) {
    for (final value in group) {
      final id = value.trim();
      if (id.isNotEmpty && seen.add(id)) {
        ids.add(id);
      }
    }
  }
  return ids;
}

class _NewestAlbumHealthProbe {
  const _NewestAlbumHealthProbe({
    required this.artistIds,
    required this.discrepantAlbums,
  });

  final Set<String> artistIds;
  final List<Album> discrepantAlbums;
}

class DriftLibrarySyncEngine implements LibrarySyncEngine {
  DriftLibrarySyncEngine({
    required LibrarySyncApi api,
    required NavisDatabase database,
    required ServerConfigRepository serverConfigRepository,
    this.networkType = NetworkType.other,
    this.staleAfter = const Duration(hours: 1),
    this.auxiliarySyncStaleAfter = _defaultAuxiliarySyncStaleAfter,
    this.fastPathPageSize = 500,
    this.fastPathMaxPages = 200,
    this.bulkSearchPageSize = 1000,
    this.bulkSearchMaxPages = 200,
    this.bulkSearchProbeQueries = const <String>['', '*'],
    this.fallbackArtistConcurrency = 4,
    this.wifiAlbumConcurrency = 8,
    this.cellularAlbumConcurrency = 1,
    this.otherAlbumConcurrency = 6,
    this.wifiMaxAlbumConcurrency = 24,
    this.cellularMaxAlbumConcurrency = 2,
    this.otherMaxAlbumConcurrency = 12,
    this.writeChunkSize = 48,
    this.isolateThreshold = 100,
    this.onBeforeSongIdentityRemap,
    this.readActiveSongId,
  }) : _api = api,
       _database = database,
       _serverConfigRepository = serverConfigRepository;

  final LibrarySyncApi _api;
  final NavisDatabase _database;
  final ServerConfigRepository _serverConfigRepository;
  final NetworkType networkType;
  final Duration staleAfter;
  final Duration auxiliarySyncStaleAfter;
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
  final Future<void> Function(Map<String, String> aliases)?
  onBeforeSongIdentityRemap;
  final String? Function()? readActiveSongId;

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
      manual: false,
      verificationContinuation: false,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> syncNow({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: true,
      forceFull: false,
      manual: true,
      verificationContinuation: false,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> continueVerification({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: true,
      forceFull: false,
      manual: false,
      verificationContinuation: true,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> forceFullSync({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: true,
      forceFull: true,
      manual: true,
      verificationContinuation: false,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  Future<LibrarySyncState> _runWithLock({
    required bool force,
    required bool forceFull,
    required bool manual,
    required bool verificationContinuation,
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
      manual: manual,
      verificationContinuation: verificationContinuation,
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
    required bool manual,
    required bool verificationContinuation,
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

    final mode = _resolveMode(serverConfig, forceFull: forceFull);
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
        freshness: _readStoredLibraryFreshness(serverConfig.capabilitiesJson),
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
    final pendingArtistIds = _readPendingArtistIds(
      serverConfig.capabilitiesJson,
    );
    final pendingArtistOffset = _readNavisIntCapability(
      serverConfig.capabilitiesJson,
      _libraryPendingOffsetCapabilityKey,
    ).clamp(0, pendingArtistIds.length);
    final pendingArtistVerificationCount =
        pendingArtistIds.length - pendingArtistOffset;

    if (!force &&
        hasFreshSync &&
        pendingHydrationCount == 0 &&
        pendingArtistVerificationCount == 0) {
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
      final auxiliaryDue = _shouldSyncAuxiliary(serverConfig.capabilitiesJson);
      final syncAuxiliary = manual || auxiliaryDue;
      if ((!force ||
              (verificationContinuation &&
                  pendingArtistVerificationCount == 0)) &&
          hasFreshSync &&
          pendingHydrationCount > 0) {
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
        state = await _finalizeHydrationOnlyVerification(state, metrics);
      } else if (mode == LibrarySyncMode.incremental) {
        state = await _runIncrementalSync(
          state: state,
          serverConfig: serverConfig,
          manual: manual,
          priorityAlbumIds: priorityAlbumIds,
          syncAuxiliary: syncAuxiliary,
          metrics: metrics,
          onProgress: onProgress,
        );
      } else {
        state = await _runFullSync(
          state: state,
          serverConfig: serverConfig,
          mode: mode,
          priorityAlbumIds: priorityAlbumIds,
          syncAuxiliary: true,
          metrics: metrics,
          onProgress: onProgress,
        );
      }

      final garbageCollected = await _database.songIdentityDao
          .garbageCollectUnreferencedProvisionalMetadata();
      if (garbageCollected.songs > 0 ||
          garbageCollected.albums > 0 ||
          garbageCollected.artists > 0) {
        metrics.addDbWriteBatch();
        AppLogger.info(
          'Provisional metadata garbage collection: '
          'songs=${garbageCollected.songs} '
          'albums=${garbageCollected.albums} '
          'artists=${garbageCollected.artists}.',
        );
      }

      if (manual ||
          (metrics.metadataChanged && !metrics.verificationContinuation) ||
          auxiliaryDue) {
        await _reconcileStarredContent(metrics);
        await _markAuxiliarySynced(DateTime.now(), metrics);
      } else {
        metrics.skippedReason = metrics.skippedReason ?? 'auxiliaryFresh';
      }

      final pendingAlbums =
          state.pendingHydrationCount ??
          await _database.libraryDao.countPendingHydrationAlbums();
      await _persistFailureDiagnosticsBestEffort(
        metrics,
        clearWhenEmpty:
            state.freshness == LibrarySyncFreshness.current &&
            state.remainingVerificationCount == 0 &&
            pendingAlbums == 0,
      );

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
      if (metrics.failureDiagnostics.isEmpty) {
        metrics.recordFailureDiagnostic(
          stage: state.stage.name,
          endpoint: 'sync',
          entityId: 'sync',
          error: error,
          attempts: 1,
        );
      }
      await _persistFailureDiagnosticsBestEffort(
        metrics,
        clearWhenEmpty: false,
      );
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
      final starred = await _withRetry(
        _api.getStarredContent,
        metrics: metrics,
        endpoint: 'getStarredContent',
      );
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
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Starred content reconciliation failed: $error\n$stackTrace',
      );
    }
  }

  LibrarySyncMode _resolveMode(
    ServerConfigModel config, {
    required bool forceFull,
  }) {
    if (forceFull) {
      return LibrarySyncMode.forceFull;
    }

    if (config.lastSynced == null) {
      return LibrarySyncMode.fullInitial;
    }

    return LibrarySyncMode.incremental;
  }

  bool _shouldSyncAuxiliary(String? capabilitiesJson) {
    final lastAuxiliarySync = _readStoredAuxiliarySyncedAt(capabilitiesJson);
    if (lastAuxiliarySync == null) {
      return true;
    }
    return DateTime.now().difference(lastAuxiliarySync) >=
        auxiliarySyncStaleAfter;
  }

  Future<void> _updateStoredIndexesFingerprint(
    String fingerprint,
    _SyncRunMetrics metrics,
  ) async {
    final serverConfig = await _serverConfigRepository.getActiveServer();
    final currentCapabilitiesJson = serverConfig?.capabilitiesJson;
    final nextCapabilitiesJson = _mergeStoredIndexesFingerprint(
      currentCapabilitiesJson,
      fingerprint,
    );
    if (nextCapabilitiesJson == currentCapabilitiesJson) {
      return;
    }
    await _serverConfigRepository.updateCapabilitiesJson(nextCapabilitiesJson);
    metrics.addDbWriteBatch();
  }

  Future<void> _markAuxiliarySynced(
    DateTime syncedAt,
    _SyncRunMetrics metrics,
  ) async {
    final serverConfig = await _serverConfigRepository.getActiveServer();
    final currentCapabilitiesJson = serverConfig?.capabilitiesJson;
    final nextCapabilitiesJson = _mergeStoredAuxiliarySyncedAt(
      currentCapabilitiesJson,
      syncedAt,
    );
    if (nextCapabilitiesJson == currentCapabilitiesJson) {
      return;
    }
    await _serverConfigRepository.updateCapabilitiesJson(nextCapabilitiesJson);
    metrics.addDbWriteBatch();
  }

  Future<void> _updateVerificationCapabilities(
    Map<String, Object?> changes,
    _SyncRunMetrics metrics,
  ) async {
    final serverConfig = await _serverConfigRepository.getActiveServer();
    final currentCapabilitiesJson = serverConfig?.capabilitiesJson;
    final nextCapabilitiesJson = _mergeNavisCapabilities(
      currentCapabilitiesJson,
      changes,
    );
    if (nextCapabilitiesJson == currentCapabilitiesJson) {
      return;
    }
    await _serverConfigRepository.updateCapabilitiesJson(nextCapabilitiesJson);
    metrics.addDbWriteBatch();
  }

  Future<void> _persistFailureDiagnostics(
    _SyncRunMetrics metrics, {
    required bool clearWhenEmpty,
  }) async {
    if (metrics.failureDiagnostics.isEmpty && !clearWhenEmpty) {
      return;
    }
    await _updateVerificationCapabilities(
      <String, Object?>{
        _librarySyncFailureDiagnosticsCapabilityKey:
            metrics.failureDiagnostics.isEmpty
            ? null
            : jsonEncode(
                metrics.failureDiagnostics
                    .map((diagnostic) => diagnostic.toJson())
                    .toList(growable: false),
              ),
        _librarySyncFailureRecordedAtCapabilityKey:
            metrics.failureDiagnostics.isEmpty ? null : DateTime.now(),
      },
      metrics,
    );
  }

  Future<void> _persistFailureDiagnosticsBestEffort(
    _SyncRunMetrics metrics, {
    required bool clearWhenEmpty,
  }) async {
    try {
      await _persistFailureDiagnostics(
        metrics,
        clearWhenEmpty: clearWhenEmpty,
      );
    } on Object catch (error, stackTrace) {
      AppLogger.warning(
        'Could not persist library sync failure diagnostics: '
        '${error.runtimeType}.\n$stackTrace',
      );
    }
  }

  Future<_NewestAlbumHealthProbe> _runNewestAlbumHealthProbe(
    _SyncRunMetrics metrics,
  ) async {
    final localAlbums = await _database.libraryDao.getAllAlbums();
    final localById = <String, AlbumsTableData>{
      for (final album in localAlbums) album.id: album,
    };
    DateTime? latestLocalCreated;
    for (final album in localAlbums) {
      final created = album.serverCreatedAt;
      if (created != null &&
          (latestLocalCreated == null || created.isAfter(latestLocalCreated))) {
        latestLocalCreated = created;
      }
    }

    final firstPage = await _withRetry(
      () => _api.getNewestAlbumListPage(
        size: _newestAlbumHealthProbePageSize,
        offset: 0,
      ),
      metrics: metrics,
      endpoint: 'getNewestAlbumList2',
    );
    final pages = <Album>[...firstPage];
    final firstPageEntirelyNewerOrUnknown =
        firstPage.length == _newestAlbumHealthProbePageSize &&
        firstPage.every((album) {
          if (!localById.containsKey(album.id)) {
            return true;
          }
          final created = album.created;
          return created != null &&
              (latestLocalCreated == null ||
                  created.isAfter(latestLocalCreated));
        });
    if (firstPageEntirelyNewerOrUnknown) {
      pages.addAll(
        await _withRetry(
          () => _api.getNewestAlbumListPage(
            size: _newestAlbumHealthProbePageSize,
            offset: _newestAlbumHealthProbePageSize,
          ),
          metrics: metrics,
          endpoint: 'getNewestAlbumList2',
        ),
      );
    }

    final discrepantAlbums = <Album>[];
    final artistIds = <String>{};
    for (final album in _dedupeAlbums(pages)) {
      final existing = localById[album.id];
      if (existing == null || _albumMetadataChanged(existing, album)) {
        discrepantAlbums.add(album);
        final artistId = album.artistId?.trim();
        if (artistId != null && artistId.isNotEmpty) {
          artistIds.add(artistId);
        }
      }
    }
    return _NewestAlbumHealthProbe(
      artistIds: artistIds,
      discrepantAlbums: discrepantAlbums,
    );
  }

  Future<List<String>> _prioritizeVerificationArtists({
    required Map<String, Artist> snapshotArtists,
    required Set<String> healthProbeArtistIds,
    bool includeRemaining = true,
  }) async {
    final localArtists = await _database.libraryDao.getAllArtists();
    final localById = <String, ArtistsTableData>{
      for (final artist in localArtists) artist.id: artist,
    };
    final missing = <String>[];
    final countChanged = <String>[];
    final missingFromSnapshot = <String>[];
    final remaining = <String>[];
    final ids = snapshotArtists.keys.toList(growable: false)..sort();
    for (final id in ids) {
      final local = localById[id];
      final remote = snapshotArtists[id]!;
      if (local == null) {
        missing.add(id);
      } else if (remote.albumCount != null &&
          local.albumCount != remote.albumCount) {
        countChanged.add(id);
      } else {
        remaining.add(id);
      }
    }
    for (final localId in localById.keys) {
      if (!snapshotArtists.containsKey(localId)) {
        missingFromSnapshot.add(localId);
      }
    }
    missingFromSnapshot.sort();
    final prioritized = <String>[];
    final seen = <String>{};
    void addAll(Iterable<String> values) {
      for (final value in values) {
        if (seen.add(value)) {
          prioritized.add(value);
        }
      }
    }

    addAll(missing);
    addAll(countChanged);
    addAll(healthProbeArtistIds.toList(growable: false)..sort());
    addAll(missingFromSnapshot);
    if (includeRemaining) {
      addAll(remaining);
    }
    return prioritized;
  }

  Future<void> _refreshIndexesCursorAfterFullSync(
    _SyncRunMetrics metrics,
  ) async {
    final now = DateTime.now();
    try {
      final indexes = await _withRetry(
        _api.getIndexes,
        metrics: metrics,
        endpoint: 'getIndexes',
      );
      final cursor = indexes.lastModified;
      if (cursor == null) {
        await _updateVerificationCapabilities(
          <String, Object?>{
            _libraryIndexesUnsupportedAtCapabilityKey: now,
            _libraryHealthCheckedAtCapabilityKey: now,
            _libraryPendingFingerprintCapabilityKey: null,
            _libraryPendingCursorCapabilityKey: null,
            _libraryPendingOffsetCapabilityKey: null,
            _libraryPendingArtistIdsCapabilityKey: null,
            _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
          },
          metrics,
        );
        return;
      }
      await _updateStoredIndexesFingerprint(
        _fingerprintIndexes(indexes),
        metrics,
      );
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryIndexesCursorCapabilityKey: cursor,
          _libraryIndexesUnsupportedAtCapabilityKey: null,
          _libraryHealthCheckedAtCapabilityKey: now,
          _libraryPendingFingerprintCapabilityKey: null,
          _libraryPendingCursorCapabilityKey: null,
          _libraryPendingOffsetCapabilityKey: null,
          _libraryPendingArtistIdsCapabilityKey: null,
          _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
        },
        metrics,
      );
    } on Object catch (error) {
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      if (!_isIndexesUnsupported(error)) {
        AppLogger.warning(
          'Could not establish the post-full-sync indexes cursor: $error',
        );
      }
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryIndexesUnsupportedAtCapabilityKey: now,
          _libraryHealthCheckedAtCapabilityKey: now,
          _libraryPendingFingerprintCapabilityKey: null,
          _libraryPendingCursorCapabilityKey: null,
          _libraryPendingOffsetCapabilityKey: null,
          _libraryPendingArtistIdsCapabilityKey: null,
          _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
        },
        metrics,
      );
    }
  }

  Future<LibrarySyncState> _finalizeHydrationOnlyVerification(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
  ) async {
    final pendingHydrationCount = await _database.libraryDao
        .countPendingHydrationAlbums();
    if (pendingHydrationCount > 0) {
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryFreshnessCapabilityKey:
              LibrarySyncFreshness.verificationPending.name,
        },
        metrics,
      );
      return state.copyWith(
        pendingHydrationCount: pendingHydrationCount,
        freshness: LibrarySyncFreshness.verificationPending,
      );
    }

    final config = await _serverConfigRepository.getActiveServer();
    final pendingArtistIds = _readPendingArtistIds(config?.capabilitiesJson);
    final pendingOffset = _readNavisIntCapability(
      config?.capabilitiesJson,
      _libraryPendingOffsetCapabilityKey,
    ).clamp(0, pendingArtistIds.length);
    final remainingArtistCount = pendingArtistIds.length - pendingOffset;
    if (remainingArtistCount > 0) {
      return state.copyWith(
        pendingHydrationCount: 0,
        remainingVerificationCount: remainingArtistCount,
        freshness: LibrarySyncFreshness.verificationPending,
      );
    }

    if (pendingArtistIds.isNotEmpty) {
      final pendingCursor = _readNavisDateCapability(
        config?.capabilitiesJson,
        _libraryPendingCursorCapabilityKey,
      );
      await _updateVerificationCapabilities(
        <String, Object?>{
          if (pendingCursor != null)
            _libraryIndexesCursorCapabilityKey: pendingCursor,
          _libraryPendingFingerprintCapabilityKey: null,
          _libraryPendingCursorCapabilityKey: null,
          _libraryPendingOffsetCapabilityKey: null,
          _libraryPendingArtistIdsCapabilityKey: null,
          _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
        },
        metrics,
      );
    } else {
      await _refreshIndexesCursorAfterFullSync(metrics);
    }
    return state.copyWith(
      pendingHydrationCount: 0,
      remainingVerificationCount: 0,
      freshness: LibrarySyncFreshness.current,
    );
  }

  Future<LibrarySyncState> _runFullSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required LibrarySyncMode mode,
    required Iterable<String> priorityAlbumIds,
    required bool syncAuxiliary,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    metrics.metadataChanged = true;
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingArtists,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    final artists = await _withRetry(
      _api.getArtists,
      metrics: metrics,
      endpoint: 'getArtists',
    );

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
    final deletedArtistIds = <String>{};
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
      deletedArtistIds.clear();
      final artistDetails = await _mapConcurrent<Artist, Artist?>(
        artists,
        _artistConcurrency,
        (artist) async {
          try {
            final detail = await _withRetry(
              () => _api.getArtist(artist.id),
              metrics: metrics,
              endpoint: 'getArtist',
            );
            current = _withMetrics(
              current.copyWith(
                processed: (current.processed ?? 0) + 1,
              ),
              metrics,
            );
            onProgress?.call(current);
            return detail;
          } on SubsonicNotFoundException {
            deletedArtistIds.add(artist.id);
            current = _withMetrics(
              current.copyWith(
                processed: (current.processed ?? 0) + 1,
              ),
              metrics,
            );
            onProgress?.call(current);
            return null;
          }
        },
      );
      for (final deletedArtistId in deletedArtistIds) {
        await _database.libraryDao.removeArtistTree(deletedArtistId);
        metrics.addDbWriteBatch();
      }
      albums = _dedupeAlbums([
        for (final artist in artistDetails.whereType<Artist>())
          ...artist.albums,
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
    final nextArtistIds = artists
        .map((a) => a.id)
        .where((id) => !deletedArtistIds.contains(id))
        .toSet();
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
    final existingAlbums = await _database.libraryDao.getAllAlbums();
    final staleArtistIds = existingArtists
        .map((a) => a.id)
        .where((id) => !nextArtistIds.contains(id))
        .toList(growable: false);
    final staleAlbumIds = existingAlbums
        .map((a) => a.id)
        .where((id) => !nextAlbumIds.contains(id))
        .toList(growable: false);
    final preserved = await _database.libraryDao
        .preserveCachedLegacyRowsAsProvisional(
          staleArtistIds: staleArtistIds,
          staleAlbumIds: staleAlbumIds,
        );
    final removableAlbumIds = staleAlbumIds
        .where((id) => !preserved.albumIds.contains(id))
        .toList(growable: false);
    if (removableAlbumIds.isNotEmpty) {
      await _database.libraryDao.deleteAlbumsByIds(removableAlbumIds);
      metrics.addDbWriteBatch();
    }
    for (final staleId in staleArtistIds.where(
      (id) => !preserved.artistIds.contains(id),
    )) {
      await _database.libraryDao.removeArtistTree(staleId);
      metrics.addDbWriteBatch();
    }

    if (syncAuxiliary) {
      current = await _syncGenresAndPlaylistsBestEffort(
        current: current,
        metrics: metrics,
        onProgress: onProgress,
      );
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
      excludedAlbumIds: const <String>{},
      metrics: metrics,
      onProgress: onProgress,
    );
    final pendingHydrationCount =
        current.pendingHydrationCount ??
        await _database.libraryDao.countPendingHydrationAlbums();
    if (pendingHydrationCount == 0) {
      await _refreshIndexesCursorAfterFullSync(metrics);
    } else {
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryFreshnessCapabilityKey:
              LibrarySyncFreshness.verificationPending.name,
        },
        metrics,
      );
    }

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        mode: mode,
        freshness: pendingHydrationCount == 0
            ? LibrarySyncFreshness.current
            : LibrarySyncFreshness.verificationPending,
        remainingVerificationCount: 0,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);
    return current;
  }

  Future<LibrarySyncState> _runIncrementalSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required bool manual,
    required Iterable<String> priorityAlbumIds,
    required bool syncAuxiliary,
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

    final capabilitiesJson = serverConfig.capabilitiesJson;
    final committedCursor = _readNavisDateCapability(
      capabilitiesJson,
      _libraryIndexesCursorCapabilityKey,
    );
    final unsupportedAt = _readNavisDateCapability(
      capabilitiesJson,
      _libraryIndexesUnsupportedAtCapabilityKey,
    );
    final now = DateTime.now();
    final shouldRetryIndexes =
        unsupportedAt == null ||
        now.difference(unsupportedAt) >= _indexesCapabilityRetryAfter;

    Indexes? indexes;
    var indexesReliable = false;
    if (shouldRetryIndexes) {
      try {
        final fetchedIndexes = await _withRetry(
          () => _api.getIndexes(ifModifiedSince: committedCursor),
          metrics: metrics,
          endpoint: 'getIndexes',
        );
        indexes = fetchedIndexes;
        final targetCursor = fetchedIndexes.lastModified;
        indexesReliable =
            targetCursor != null &&
            (committedCursor == null ||
                !targetCursor.isBefore(committedCursor));
        if (!indexesReliable) {
          AppLogger.warning(
            'getIndexes returned an absent or regressing lastModified cursor; '
            'using bounded verification.',
          );
          await _updateVerificationCapabilities(
            <String, Object?>{
              _libraryIndexesUnsupportedAtCapabilityKey: now,
            },
            metrics,
          );
        } else {
          await _updateVerificationCapabilities(
            <String, Object?>{
              _libraryIndexesUnsupportedAtCapabilityKey: null,
            },
            metrics,
          );
        }
      } on Object catch (error) {
        if (!_isIndexesUnsupported(error)) {
          rethrow;
        }
        AppLogger.info(
          'getIndexes is unsupported; using bounded artist and newest-album '
          'verification.',
        );
        await _updateVerificationCapabilities(
          <String, Object?>{
            _libraryIndexesUnsupportedAtCapabilityKey: now,
          },
          metrics,
        );
      }
    }

    final fallbackVerification = !indexesReliable;
    if (fallbackVerification &&
        networkType == NetworkType.cellular &&
        !manual) {
      metrics.skippedReason = 'verificationRequiresNonCellular';
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryFreshnessCapabilityKey:
              LibrarySyncFreshness.repairRecommended.name,
        },
        metrics,
      );
      return _withMetrics(
        current.copyWith(
          mode: LibrarySyncMode.incremental,
          stage: LibrarySyncStage.finalizing,
          freshness: LibrarySyncFreshness.repairRecommended,
          clearProcessed: true,
          clearTotal: true,
        ),
        metrics,
      );
    }

    final snapshotArtists = <String, Artist>{};
    if (indexesReliable && indexes != null) {
      snapshotArtists.addAll(_indexArtistsById(indexes));
    } else {
      final artists = await _withRetry(
        _api.getArtists,
        metrics: metrics,
        endpoint: 'getArtists',
      );
      snapshotArtists.addEntries(
        artists
            .where((artist) => artist.id.trim().isNotEmpty)
            .map((artist) => MapEntry<String, Artist>(artist.id, artist)),
      );
    }

    final lastHealthCheck = _readNavisDateCapability(
      capabilitiesJson,
      _libraryHealthCheckedAtCapabilityKey,
    );
    final healthProbeDue =
        fallbackVerification ||
        lastHealthCheck == null ||
        now.difference(lastHealthCheck) >= _defaultHealthProbeStaleAfter;
    var healthProbe = const _NewestAlbumHealthProbe(
      artistIds: <String>{},
      discrepantAlbums: <Album>[],
    );
    if (healthProbeDue) {
      healthProbe = await _runNewestAlbumHealthProbe(metrics);
      await _updateVerificationCapabilities(
        <String, Object?>{_libraryHealthCheckedAtCapabilityKey: now},
        metrics,
      );
    }

    final indexesFingerprint = indexesReliable && indexes != null
        ? _fingerprintIndexes(indexes)
        : _fingerprintArtistIds(snapshotArtists.keys);
    final targetCursor = indexesReliable ? indexes?.lastModified : null;
    final pendingFingerprint = _readNavisStringCapability(
      capabilitiesJson,
      _libraryPendingFingerprintCapabilityKey,
    );
    final pendingTargetCursor = _readNavisDateCapability(
      capabilitiesJson,
      _libraryPendingCursorCapabilityKey,
    );
    final storedPendingArtistIds = _readPendingArtistIds(capabilitiesJson);
    metrics.verificationContinuation = storedPendingArtistIds.isNotEmpty;
    final storedPendingOffset = _readNavisIntCapability(
      capabilitiesJson,
      _libraryPendingOffsetCapabilityKey,
    ).clamp(0, storedPendingArtistIds.length);
    final samePendingSnapshot =
        pendingFingerprint == indexesFingerprint &&
        storedPendingArtistIds.isNotEmpty &&
        (targetCursor == null ||
            pendingTargetCursor == null ||
            targetCursor.toUtc() == pendingTargetCursor.toUtc());

    final cursorChanged =
        targetCursor != null &&
        (committedCursor == null ||
            targetCursor.toUtc() != committedCursor.toUtc());
    final urgentArtistIds = await _prioritizeVerificationArtists(
      snapshotArtists: snapshotArtists,
      healthProbeArtistIds: healthProbe.artistIds,
      includeRemaining: false,
    );
    final fullAuditArtistIds = await _prioritizeVerificationArtists(
      snapshotArtists: snapshotArtists,
      healthProbeArtistIds: healthProbe.artistIds,
    );
    final storedRemainingArtistIds = storedPendingArtistIds.sublist(
      storedPendingOffset,
    );
    var pendingOffset = 0;
    late List<String> orderedArtistIds;
    if (samePendingSnapshot) {
      orderedArtistIds = storedPendingArtistIds;
      pendingOffset = storedPendingOffset;
    } else if (storedRemainingArtistIds.isNotEmpty) {
      final newlyReportedArtistIds =
          snapshotArtists.keys
              .where((id) => !storedPendingArtistIds.contains(id))
              .toList(growable: false)
            ..sort();
      orderedArtistIds = _dedupeArtistIds(<Iterable<String>>[
        newlyReportedArtistIds,
        urgentArtistIds,
        storedRemainingArtistIds,
        fullAuditArtistIds,
      ]);
    } else if (indexesReliable && !cursorChanged) {
      orderedArtistIds = healthProbe.artistIds.toList(growable: false)..sort();
    } else {
      orderedArtistIds = fullAuditArtistIds;
    }
    if (healthProbe.artistIds.isNotEmpty && samePendingSnapshot) {
      final remaining = orderedArtistIds.sublist(pendingOffset);
      final prioritizedRemaining = _dedupeArtistIds(<Iterable<String>>[
        healthProbe.artistIds.toList(growable: false)..sort(),
        remaining,
      ]);
      if (prioritizedRemaining.length == remaining.length) {
        orderedArtistIds
          ..removeRange(pendingOffset, orderedArtistIds.length)
          ..addAll(prioritizedRemaining);
      }
    }

    final passLimit = networkType == NetworkType.cellular
        ? _cellularManualArtistVerificationLimit
        : _normalArtistVerificationLimit;
    final passEnd = (pendingOffset + passLimit).clamp(
      0,
      orderedArtistIds.length,
    );
    final passArtistIds = orderedArtistIds.sublist(pendingOffset, passEnd);

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.fetchingAlbums,
        processed: 0,
        total: passArtistIds.length,
      ),
      metrics,
    );
    onProgress?.call(current);

    final deletedArtistIds = <String>{};
    final failedArtistIds = <String>{};
    final details = await _mapConcurrent<String, Artist?>(
      passArtistIds,
      _artistConcurrency,
      (artistId) async {
        var attempts = 1;
        void publishArtistProgress() {
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
        }

        try {
          final artist = await _withRetry(
            () => _api.getArtist(artistId),
            metrics: metrics,
            endpoint: 'getArtist',
            onFinalFailure: (error, finalAttempts) {
              attempts = finalAttempts;
            },
          );
          publishArtistProgress();
          return artist;
        } on SubsonicNotFoundException {
          deletedArtistIds.add(artistId);
          publishArtistProgress();
          return null;
        } on Object catch (error) {
          metrics.recordFailureDiagnostic(
            stage: LibrarySyncStage.fetchingAlbums.name,
            endpoint: 'getArtist',
            entityId: artistId,
            error: error,
            attempts: attempts,
          );
          if (_isFatalEntityError(error)) {
            rethrow;
          }
          failedArtistIds.add(artistId);
          publishArtistProgress();
          return null;
        }
      },
    );

    final completedPassArtistIds = passArtistIds
        .where((artistId) => !failedArtistIds.contains(artistId))
        .toList(growable: false);
    final untouchedTail = orderedArtistIds.sublist(passEnd);
    orderedArtistIds = _dedupeArtistIds(<Iterable<String>>[
      orderedArtistIds.sublist(0, pendingOffset),
      completedPassArtistIds,
      untouchedTail,
      passArtistIds.where(failedArtistIds.contains),
    ]);
    final nextPendingOffset = pendingOffset + completedPassArtistIds.length;
    final remainingVerificationCount =
        orderedArtistIds.length - nextPendingOffset;
    if (remainingVerificationCount > 0) {
      metrics.skippedReason = failedArtistIds.isEmpty
          ? 'verificationContinuation'
          : 'artistVerificationPending';
    }

    final artistDetails = details.whereType<Artist>().toList(growable: false);
    final touchedArtistIds = artistDetails.map((artist) => artist.id).toSet();
    final changedArtistDetails = <Artist>[];
    for (final artist in artistDetails) {
      final existing = await _database.libraryDao.getArtistById(artist.id);
      if (existing == null || _artistMetadataChanged(existing, artist)) {
        changedArtistDetails.add(artist);
      }
    }
    if (changedArtistDetails.isNotEmpty || deletedArtistIds.isNotEmpty) {
      metrics.metadataChanged = true;
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    if (changedArtistDetails.isNotEmpty) {
      await _database.libraryDao.upsertArtists(
        _toArtistCompanions(changedArtistDetails),
      );
      metrics.addDbWriteBatch();
    }

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
      metrics.metadataChanged = true;
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
      metrics.metadataChanged = true;
      await _database.libraryDao.markAlbumsSongsHydratedByIds(
        hydratedWithoutSongRefresh,
      );
      metrics.addDbWriteBatch();
    }
    if (albumsNeedingHydration.isNotEmpty) {
      metrics.metadataChanged = true;
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
        metrics.metadataChanged = true;
        await _database.libraryDao.deleteAlbumsByIds(staleAlbumIds);
        metrics.addDbWriteBatch();
      }
    }

    for (final deletedArtistId in deletedArtistIds) {
      metrics.metadataChanged = true;
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

    if (syncAuxiliary ||
        (metrics.metadataChanged && !metrics.verificationContinuation)) {
      current = await _syncGenresAndPlaylistsBestEffort(
        current: current,
        metrics: metrics,
        onProgress: onProgress,
      );
    }

    await _updateStoredIndexesFingerprint(indexesFingerprint, metrics);
    final pendingHydrationCount =
        current.pendingHydrationCount ??
        await _database.libraryDao.countPendingHydrationAlbums();
    final hasPendingVerification =
        remainingVerificationCount > 0 || pendingHydrationCount > 0;
    if (hasPendingVerification) {
      await _updateVerificationCapabilities(
        <String, Object?>{
          _libraryPendingFingerprintCapabilityKey: indexesFingerprint,
          _libraryPendingCursorCapabilityKey: targetCursor,
          _libraryPendingOffsetCapabilityKey: nextPendingOffset,
          _libraryPendingArtistIdsCapabilityKey: jsonEncode(orderedArtistIds),
          _libraryFreshnessCapabilityKey:
              LibrarySyncFreshness.verificationPending.name,
        },
        metrics,
      );
    } else {
      await _updateVerificationCapabilities(
        <String, Object?>{
          if (targetCursor != null)
            _libraryIndexesCursorCapabilityKey: targetCursor,
          _libraryPendingFingerprintCapabilityKey: null,
          _libraryPendingCursorCapabilityKey: null,
          _libraryPendingOffsetCapabilityKey: null,
          _libraryPendingArtistIdsCapabilityKey: null,
          _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
        },
        metrics,
      );
    }

    return _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        clearProcessed: true,
        clearTotal: true,
        remainingVerificationCount: remainingVerificationCount,
        freshness: hasPendingVerification
            ? LibrarySyncFreshness.verificationPending
            : LibrarySyncFreshness.current,
        mode: touchedArtistIds.isEmpty
            ? LibrarySyncMode.incremental
            : current.mode,
      ),
      metrics,
    );
  }

  Future<LibrarySyncState> _syncGenresAndPlaylistsBestEffort({
    required LibrarySyncState current,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    var state = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingGenres),
      metrics,
    );
    onProgress?.call(state);
    try {
      final genres = await _withRetry(
        _api.getGenres,
        metrics: metrics,
        endpoint: 'getGenres',
      );
      await _database.libraryDao.replaceGenres(_toGenreCompanions(genres));
      metrics.addDbWriteBatch();
    } on Object catch (error, stackTrace) {
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Genre sync skipped after failure: $error\n$stackTrace',
      );
    }

    state = _withMetrics(
      state.copyWith(stage: LibrarySyncStage.fetchingPlaylists),
      metrics,
    );
    onProgress?.call(state);
    try {
      final playlists = await _withRetry(
        _api.getPlaylists,
        metrics: metrics,
        endpoint: 'getPlaylists',
      );
      await _database.playlistDao.upsertPlaylists(
        _toPlaylistCompanions(playlists),
      );
      metrics.addDbWriteBatch();
    } on Object catch (error, stackTrace) {
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      AppLogger.warning(
        'Playlist sync skipped after failure: $error\n$stackTrace',
      );
    }

    return state;
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
    final requeueAlbumIds = <String>{};
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

    Future<void> resolveRemovedAlbums(Iterable<String> albumIds) async {
      var removed = 0;
      for (final albumId in albumIds) {
        if (pendingAlbumIds.remove(albumId)) {
          prioritized.remove(albumId);
          observedBulkAlbumIds.remove(albumId);
          removed++;
        }
      }
      if (removed == 0) {
        return;
      }
      pendingRemaining -= removed;
      metrics.deletedAlbums += removed;
      current = _withMetrics(
        current.copyWith(
          metadataReady: true,
          isHydrating: true,
          pendingHydrationCount: pendingRemaining < 0 ? 0 : pendingRemaining,
        ),
        metrics,
      );
      onProgress?.call(current);
    }

    Future<void> processAlbumBatch(_AlbumBatchFetchResult batchResult) async {
      if (batchResult.deletedAlbumIds.isNotEmpty) {
        await resolveRemovedAlbums(batchResult.deletedAlbumIds);
      }
      requeueAlbumIds.addAll(batchResult.requeueAlbumIds);
      if (batchResult.requeueAlbumIds.isNotEmpty) {
        for (final albumId in batchResult.requeueAlbumIds) {
          if (pendingAlbumIds.remove(albumId)) {
            prioritized.remove(albumId);
            observedBulkAlbumIds.remove(albumId);
            pendingRemaining--;
          }
        }
        current = _withMetrics(
          current.copyWith(
            metadataReady: true,
            isHydrating: true,
            pendingHydrationCount: pendingRemaining < 0 ? 0 : pendingRemaining,
          ),
          metrics,
        );
        onProgress?.call(current);
      }
      if (batchResult.hardFailedAlbumIds.isNotEmpty) {
        for (final albumId in batchResult.hardFailedAlbumIds) {
          if (pendingAlbumIds.remove(albumId)) {
            prioritized.remove(albumId);
            observedBulkAlbumIds.remove(albumId);
            pendingRemaining--;
          }
        }
        current = _withMetrics(
          current.copyWith(
            metadataReady: true,
            isHydrating: true,
            pendingHydrationCount: pendingRemaining < 0 ? 0 : pendingRemaining,
          ),
          metrics,
        );
        onProgress?.call(current);
      }

      if (batchResult.albums.isEmpty) {
        return;
      }

      final songsByAlbum = <String, List<SongsTableCompanion>>{};
      final hydratedAlbumIds = <String>[];
      for (final detail in batchResult.albums) {
        songsByAlbum[detail.id] = await _toSongCompanions(
          detail.songs,
          defaultAlbumId: detail.id,
          validArtistIds: validArtistIds,
        );
        hydratedAlbumIds.add(detail.id);
      }

      final canonicalSongIds = songsByAlbum.values
          .expand((songs) => songs)
          .where((song) => song.id.present)
          .map((song) => song.id.value)
          .toSet();
      final sameIdProvisionalSongs =
          (await _database.songIdentityDao.getProvisionalSongs())
              .map((song) => song.id)
              .toSet();
      await _database.libraryDao.replaceSongsForAlbumsChunk(songsByAlbum);
      metrics.addDbWriteBatch();
      await _reconcileHydratedSongIds(
        canonicalSongIds: canonicalSongIds,
        sameIdProvisionalSongs: sameIdProvisionalSongs,
        metrics: metrics,
      );
      await _database.libraryDao.markAlbumsSongsHydratedByIds(hydratedAlbumIds);
      metrics.addDbWriteBatch();
      await publishProgress(hydratedAlbumIds);
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

      final batchResult = await _fetchAlbumDetailsAdaptive(
        chunk: chunk,
        concurrencyController: concurrencyController,
        metrics: metrics,
      );

      await processAlbumBatch(batchResult);
      // Yield to the event loop between write batches so the UI can
      // render frames and respond to user input during long hydrations.
      await Future<void>.delayed(Duration.zero);
    }

    if (requeueAlbumIds.isNotEmpty) {
      final retryRows = await _database.libraryDao
          .getPendingHydrationAlbumsByIds(
            requeueAlbumIds.toList(growable: false),
            limit: requeueAlbumIds.length,
          );
      if (retryRows.isNotEmpty) {
        final retryController = _AdaptiveHydrationConcurrency(
          initial: 1,
          min: 1,
          max: 2,
        );
        final retryResult = await _fetchAlbumDetailsAdaptive(
          chunk: retryRows,
          concurrencyController: retryController,
          metrics: metrics,
        );
        await processAlbumBatch(retryResult);
      }
    }

    final remainingPending = await _database.libraryDao
        .countPendingHydrationAlbums();
    if (remainingPending > 0) {
      metrics.skippedReason = 'albumHydrationPending';
    }

    return _withMetrics(
      current.copyWith(
        metadataReady: true,
        isHydrating: false,
        fastPathActive: false,
        pendingHydrationCount: remainingPending,
        freshness: remainingPending > 0
            ? LibrarySyncFreshness.verificationPending
            : current.freshness,
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
          endpoint: 'searchSongsPage',
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
    final importedSongsByAlbum = <String, Map<String, Song>>{};

    Future<void> markHydrated(Iterable<String> albumIds) async {
      final ids = albumIds.toSet().toList(growable: false);
      if (ids.isEmpty) {
        return;
      }
      await _database.libraryDao.markAlbumsSongsHydratedByIds(ids);
      metrics.addDbWriteBatch();
      await onHydratedChunk(ids);
    }

    Future<void> reconcileAndMarkHydrated(Iterable<String> albumIds) async {
      final ids = albumIds.toSet().toList(growable: false);
      if (ids.isEmpty) {
        return;
      }
      final songsByAlbum = <String, List<SongsTableCompanion>>{};
      for (final albumId in ids) {
        final rawSongs =
            importedSongsByAlbum[albumId]?.values.toList(growable: false) ??
            const <Song>[];
        songsByAlbum[albumId] = await _toSongCompanions(
          rawSongs,
          defaultAlbumId: albumId,
          validArtistIds: validArtistIds,
        );
      }
      final canonicalSongIds = songsByAlbum.values
          .expand((songs) => songs)
          .where((song) => song.id.present)
          .map((song) => song.id.value)
          .toSet();
      final sameIdProvisionalSongs =
          (await _database.songIdentityDao.getProvisionalSongs())
              .map((song) => song.id)
              .toSet();
      await _database.libraryDao.reconcileSongsForAlbumsChunk(songsByAlbum);
      metrics.addDbWriteBatch();
      await _reconcileHydratedSongIds(
        canonicalSongIds: canonicalSongIds,
        sameIdProvisionalSongs: sameIdProvisionalSongs,
        metrics: metrics,
      );
      await markHydrated(ids);
      ids.forEach(importedSongsByAlbum.remove);
    }

    await reconcileAndMarkHydrated(
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
        endpoint: 'searchSongsPage',
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
        for (final entry in rawSongsByAlbum.entries) {
          final bySongId = importedSongsByAlbum.putIfAbsent(
            entry.key,
            () => <String, Song>{},
          );
          for (final song in entry.value) {
            bySongId[song.id] = song;
          }
          importedSongCountsByAlbum[entry.key] = bySongId.length;
        }
        await reconcileAndMarkHydrated(
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

    if (importedSongsByAlbum.isEmpty) {
      return;
    }

    await reconcileAndMarkHydrated(
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
        endpoint: 'getAlbumListPage',
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
    String? endpoint,
    void Function(Object error, int attempts)? onFinalFailure,
  }) async {
    final effectiveMaxAttempts = networkType == NetworkType.cellular
        ? maxAttempts.clamp(1, 2)
        : maxAttempts;
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
          endpoint: endpoint,
        );
        return result;
      } on SyncCancelledException {
        rethrow;
      } on Object catch (error) {
        metrics.recordApiAttempt(
          elapsed: stopwatch.elapsed,
          isRetryAttempt: attempt > 1,
          endpoint: endpoint,
        );
        if (!_isTransient(error) || attempt >= effectiveMaxAttempts) {
          metrics.recordApiFailure();
          onFinalFailure?.call(error, attempt);
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

  bool _isFatalEntityError(Object error) {
    return error is SubsonicAuthException ||
        error is SubsonicForbiddenException;
  }

  Future<_AlbumFetchResult> _fetchAlbumDetailResilient(
    String albumId, {
    required _SyncRunMetrics metrics,
  }) async {
    var attempts = 1;
    try {
      final album = await _withRetry(
        () => _api.getAlbum(albumId),
        metrics: metrics,
        endpoint: 'getAlbum',
        onFinalFailure: (error, finalAttempts) {
          attempts = finalAttempts;
        },
      );
      return _AlbumFetchResult.success(album);
    } on SyncCancelledException {
      rethrow;
    } on SubsonicNotFoundException {
      AppLogger.debug(
        'Album $albumId not found during hydration; removing local row.',
      );
      await _database.libraryDao.deleteAlbumsByIds([albumId]);
      metrics.addDbWriteBatch();
      return const _AlbumFetchResult.deleted();
    } on Object catch (error) {
      metrics.recordFailureDiagnostic(
        stage: LibrarySyncStage.fetchingSongs.name,
        endpoint: 'getAlbum',
        entityId: albumId,
        error: error,
        attempts: attempts,
      );
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      if (_isTransient(error)) {
        return const _AlbumFetchResult.requeue();
      }
      metrics.recordHardAlbumFailure();
      return const _AlbumFetchResult.hardFailure();
    }
  }

  Future<_AlbumBatchFetchResult> _fetchAlbumDetailsAdaptive({
    required List<AlbumsTableData> chunk,
    required _AdaptiveHydrationConcurrency concurrencyController,
    required _SyncRunMetrics metrics,
  }) async {
    final albums = <Album>[];
    final deletedAlbumIds = <String>[];
    final requeueAlbumIds = <String>[];
    final hardFailedAlbumIds = <String>[];
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
          (album) => _fetchAlbumDetailResilient(
            album.id,
            metrics: metrics,
          ),
        ),
      );
      batchStopwatch.stop();

      var successCount = 0;
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        final albumId = batch[index].id;
        switch (result.outcome) {
          case _AlbumFetchOutcome.success:
            albums.add(result.album!);
            successCount++;
          case _AlbumFetchOutcome.deleted:
            deletedAlbumIds.add(albumId);
          case _AlbumFetchOutcome.requeue:
            requeueAlbumIds.add(albumId);
          case _AlbumFetchOutcome.hardFailure:
            hardFailedAlbumIds.add(albumId);
        }
      }

      final avgLatencyMs = successCount == 0
          ? 0
          : (batchStopwatch.elapsedMilliseconds ~/ successCount);
      concurrencyController.observeBatch(
        averageLatencyMs: avgLatencyMs,
        hadTransientRetries: metrics.apiRetries > retriesBefore,
      );
    }

    return _AlbumBatchFetchResult(
      albums: albums,
      deletedAlbumIds: deletedAlbumIds,
      requeueAlbumIds: requeueAlbumIds,
      hardFailedAlbumIds: hardFailedAlbumIds,
    );
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
      canonicalizedSongCount: metrics.canonicalizedSongCount,
      ambiguousMatchCount: metrics.ambiguousMatchCount,
    );
  }

  Future<void> _reconcileHydratedSongIds({
    required Iterable<String> canonicalSongIds,
    required Set<String> sameIdProvisionalSongs,
    required _SyncRunMetrics metrics,
  }) async {
    final ids = canonicalSongIds.toSet();
    if (ids.isEmpty) {
      return;
    }
    final canonicalSongs = await _database.libraryDao.getSongsByIds(ids);
    final summary = await SongIdentityReconciler(
      _database.songIdentityDao,
      onBeforeRemap: onBeforeSongIdentityRemap,
      readActiveSongId: readActiveSongId,
    ).reconcileCanonicalSongs(canonicalSongs);
    metrics.canonicalizedSongCount +=
        summary.canonicalizedSongCount +
        ids.intersection(sameIdProvisionalSongs).length;
    metrics.ambiguousMatchCount += summary.ambiguousMatchCount;
    if (summary.aliases.isNotEmpty ||
        summary.ambiguousMatchCount > 0 ||
        summary.retainedProvisionalCount > 0) {
      AppLogger.info(
        'Song identity reconciliation: '
        'canonicalized=${summary.aliases.length} '
        'ambiguous=${summary.ambiguousMatchCount} '
        'retainedProvisional=${summary.retainedProvisionalCount}.',
      );
    }
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

  bool _artistMetadataChanged(ArtistsTableData current, Artist next) {
    return current.name != next.name ||
        current.albumCount != next.albumCount ||
        current.coverArt != next.coverArt ||
        current.starred != next.starred ||
        current.isProvisional;
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
      'stage=${state.stage.name} '
      'requests=${metrics.apiRequests} '
      'retries=${metrics.apiRetries} '
      'failures=${metrics.apiFailures} '
      'endpointRequests=${_formatEndpointCounts(metrics.apiRequestsByEndpoint)} '
      'metadataChanged=${metrics.metadataChanged} '
      'skippedReason=${metrics.skippedReason ?? 'none'} '
      'deletedAlbums=${metrics.deletedAlbums} '
      'hardAlbumFailures=${metrics.hardAlbumFailures} '
      'freshness=${state.freshness.name} '
      'remainingVerification=${state.remainingVerificationCount} '
      'canonicalizedSongs=${state.canonicalizedSongCount} '
      'ambiguousMatches=${state.ambiguousMatchCount} '
      'avgLatencyMs=${metrics.averageLatencyMs ?? 0} '
      'dbWriteBatches=${metrics.dbWriteBatches} '
      'hydrationAlbumsPerSecond='
      '${metrics.hydrationThroughputAlbumsPerSecond?.toStringAsFixed(2) ?? '0.00'} '
      'durationMs=${durationMs ?? 0}',
    );
  }

  String _formatEndpointCounts(Map<String, int> counts) {
    if (counts.isEmpty) {
      return '{}';
    }
    final entries = counts.entries.toList(growable: false)
      ..sort((a, b) => a.key.compareTo(b.key));
    return '{${entries.map((entry) => '${entry.key}:${entry.value}').join(',')}}';
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
            albumId: Value(defaultAlbumId ?? row.albumId),
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
            recordingMbid: Value(row.recordingMbid),
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
  static const _maxFailureDiagnostics = 12;

  int apiRequests = 0;
  int apiRetries = 0;
  int apiFailures = 0;
  int dbWriteBatches = 0;
  int deletedAlbums = 0;
  int hardAlbumFailures = 0;
  int canonicalizedSongCount = 0;
  int ambiguousMatchCount = 0;
  bool metadataChanged = false;
  bool verificationContinuation = false;
  String? skippedReason;
  final Map<String, int> apiRequestsByEndpoint = <String, int>{};
  final List<_SyncFailureDiagnostic> failureDiagnostics =
      <_SyncFailureDiagnostic>[];
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
    String? endpoint,
  }) {
    apiRequests++;
    if (endpoint != null && endpoint.isNotEmpty) {
      apiRequestsByEndpoint[endpoint] =
          (apiRequestsByEndpoint[endpoint] ?? 0) + 1;
    }
    if (isRetryAttempt) {
      apiRetries++;
    }
    _latencySumMs += elapsed.inMilliseconds;
    _latencySamples++;
  }

  void recordApiFailure() {
    apiFailures++;
  }

  void recordHardAlbumFailure() {
    hardAlbumFailures++;
  }

  void recordFailureDiagnostic({
    required String stage,
    required String endpoint,
    required String entityId,
    required Object error,
    required int attempts,
  }) {
    failureDiagnostics.removeWhere(
      (diagnostic) =>
          diagnostic.endpoint == endpoint && diagnostic.entityId == entityId,
    );
    failureDiagnostics.add(
      _SyncFailureDiagnostic(
        stage: stage,
        endpoint: endpoint,
        entityId: entityId,
        errorType: error.runtimeType.toString(),
        attempts: attempts,
      ),
    );
    if (failureDiagnostics.length > _maxFailureDiagnostics) {
      failureDiagnostics.removeRange(
        0,
        failureDiagnostics.length - _maxFailureDiagnostics,
      );
    }
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
    this.recordingMbid,
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
  final String? recordingMbid;
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
            recordingMbid: json['musicBrainzId'] as String?,
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
