import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_catalog_diff_analyzer.dart';
import 'package:navis/src/database/daos/library_sync_dao.dart';
import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/features/library/data/library_sync_response_validation.dart';
import 'package:navis/src/features/library/data/entity_identity_reconciler.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/domain/library_sync_request.dart';
import 'package:navis/src/features/library/domain/sync_run_contract.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/catalog_source.dart';

typedef LibrarySyncProgressCallback = void Function(LibrarySyncState state);

/// Thrown when a sync operation is cancelled via [DriftLibrarySyncEngine.cancelSync].
class SyncCancelledException implements Exception {
  const SyncCancelledException();
  @override
  String toString() => 'SyncCancelledException: sync was cancelled.';
}

/// Thrown when live network policy requires pausing background sync work.
class SyncNetworkDeferredException implements Exception {
  const SyncNetworkDeferredException([
    this.message = 'Sync deferred by network policy.',
  ]);

  final String message;

  @override
  String toString() => 'SyncNetworkDeferredException: $message';
}

enum _AlbumFetchOutcome { success, requeue, hardFailure }

class _AlbumFetchResult {
  const _AlbumFetchResult._(this.outcome, [this.album]);

  const _AlbumFetchResult.success(Album album)
    : this._(_AlbumFetchOutcome.success, album);

  const _AlbumFetchResult.requeue() : this._(_AlbumFetchOutcome.requeue);

  const _AlbumFetchResult.hardFailure()
    : this._(_AlbumFetchOutcome.hardFailure);

  final _AlbumFetchOutcome outcome;
  final Album? album;
}

class _AlbumBatchFetchResult {
  const _AlbumBatchFetchResult({
    required this.albums,
    required this.requeueAlbumIds,
    required this.hardFailedAlbumIds,
  });

  final List<Album> albums;
  final List<String> requeueAlbumIds;
  final List<String> hardFailedAlbumIds;
}

class _CatalogPageCheckpoint {
  const _CatalogPageCheckpoint({
    required this.count,
    required this.rawCount,
    required this.hasMore,
    required this.signature,
  });

  final int count;
  final int rawCount;
  final bool hasMore;
  final String signature;
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
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return switch (request.intent) {
      LibrarySyncIntent.automatic => syncIfStale(
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
      LibrarySyncIntent.checkForUpdates => syncNow(
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
      LibrarySyncIntent.repair => forceFullSync(
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
    };
  }

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

  /// Single conditional `getIndexes` probe with retries disabled.
  ///
  /// Never advances the committed cursor or fans out into artist/album work.
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  });
}

abstract interface class TargetedLibrarySyncExecutor {
  Future<LibrarySyncState> hydrateAlbum(
    String albumId, {
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> hydrateArtist(
    String artistId, {
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> hydratePlaylist(
    String playlistId, {
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  });

  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  });
}

/// Compatibility boundary for the typed scheduler. Implementations receive
/// the plan selected at admission time; the legacy methods remain temporary
/// adapters until the underlying executor is fully migrated.
extension LibrarySyncExecutionPlanAdapter on LibrarySyncEngine {
  Future<LibrarySyncState> executeSyncPlan(
    SyncExecutionPlan plan, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    if (this case final DriftLibrarySyncEngine engine) {
      return engine.executeSyncExecutionPlan(
        plan,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      );
    }
    final targetExecutor = switch (this) {
      final TargetedLibrarySyncExecutor executor => executor,
      _ => null,
    };
    final target = plan.request.target;
    return switch (plan.kind) {
      SyncExecutionPlanKind.automaticProbe => probeCatalog(
        onProgress: onProgress,
      ),
      SyncExecutionPlanKind.manualCatalogDiscovery => syncNow(
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
      SyncExecutionPlanKind.repairLibrary ||
      SyncExecutionPlanKind.catalogSnapshot => forceFullSync(
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
      SyncExecutionPlanKind.compatibilityAudit => switch (this) {
        final DriftLibrarySyncEngine engine => engine.runCompatibilityAudit(
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        ),
        _ => continueVerification(
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        ),
      },
      SyncExecutionPlanKind.targetHydration ||
      SyncExecutionPlanKind.auxiliaryRefresh => switch (target.kind) {
        LibrarySyncTargetKind.album
            when target.entityId != null && targetExecutor != null =>
          targetExecutor.hydrateAlbum(target.entityId!, onProgress: onProgress),
        LibrarySyncTargetKind.artist
            when target.entityId != null && targetExecutor != null =>
          targetExecutor.hydrateArtist(
            target.entityId!,
            onProgress: onProgress,
          ),
        LibrarySyncTargetKind.playlist
            when target.entityId != null && targetExecutor != null =>
          targetExecutor.hydratePlaylist(
            target.entityId!,
            onProgress: onProgress,
          ),
        LibrarySyncTargetKind.playlistHeaders when targetExecutor != null =>
          targetExecutor.syncPlaylistHeaders(onProgress: onProgress),
        LibrarySyncTargetKind.starred when targetExecutor != null =>
          targetExecutor.syncStarredContent(onProgress: onProgress),
        // Genre metadata is not part of Navis's library sync contract. Keep
        // this compatibility branch for a persisted pre-1.4 target, but do
        // not turn it into an unrelated catalog verification pass.
        LibrarySyncTargetKind.genres => _genresSyncDisabled(
          onProgress: onProgress,
        ),
        _ => continueVerification(
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        ),
      },
    };
  }
}

Future<LibrarySyncState> _genresSyncDisabled({
  LibrarySyncProgressCallback? onProgress,
}) {
  final state = LibrarySyncState(
    status: LibrarySyncStatus.skipped,
    stage: LibrarySyncStage.completed,
    completedAt: DateTime.now(),
    metadataReady: true,
  );
  onProgress?.call(state);
  return Future<LibrarySyncState>.value(state);
}

abstract class LibrarySyncApi {
  void beginRun();
  void cancelActiveRequests();
  Future<List<Artist>> getArtists();
  Future<Artist> getArtist(String id, {int? maxResponseBytes});
  Future<Album> getAlbum(String id, {int? maxResponseBytes});
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) {
    throw UnsupportedError('Targeted playlist hydration is unsupported.');
  }

  Future<StarredContent> getStarredContent();

  /// Best-effort scan-status probe. Returns null when the server does not
  /// implement `getScanStatus`; unsupported providers must not block sync.
  Future<ScanStatus?> getScanStatusOrNull() async {
    return null;
  }

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

  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  });
  Future<List<Playlist>> getPlaylists();
}

/// Metered interactive hydration budgets (bytes).
const kMeteredSyncMaxResponseBytes = 16 * 1024 * 1024;
const kMeteredSyncMaxInteractionBytes = 32 * 1024 * 1024;

class _MeteredInteractionBudget {
  _MeteredInteractionBudget({
    required this.maxResponseBytes,
    required this.maxInteractionBytes,
  });

  final int maxResponseBytes;
  final int maxInteractionBytes;
  int _used = 0;

  int remainingInteractionBytes() =>
      maxInteractionBytes > _used ? maxInteractionBytes - _used : 0;

  int nextMaxResponseBytes() {
    final remaining = remainingInteractionBytes();
    if (remaining <= 0) {
      throw SubsonicResponseBudgetExceededException(
        maxBytes: maxInteractionBytes,
        observedBytes: _used,
      );
    }
    return remaining < maxResponseBytes ? remaining : maxResponseBytes;
  }

  void recordObservedBytes(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _used += bytes;
    if (_used > maxInteractionBytes) {
      throw SubsonicResponseBudgetExceededException(
        maxBytes: maxInteractionBytes,
        observedBytes: _used,
      );
    }
  }
}

class SubsonicLibrarySyncApi implements LibrarySyncApi {
  SubsonicLibrarySyncApi(this._api);

  final SubsonicApiClient _api;
  CancelToken _cancelToken = CancelToken();

  @override
  Future<ScanStatus?> getScanStatusOrNull() async {
    try {
      return await _api.getScanStatus(cancelToken: _cancelToken);
    } on SubsonicApiException catch (error) {
      // Servers without the endpoint typically answer with the not-found
      // error code. Record that through the caller's observation handling
      // and keep synchronization on its existing discovery path; auth and
      // transport failures keep their normal retry semantics.
      if (error.code == 70) {
        return null;
      }
      rethrow;
    }
  }

  @override
  void beginRun() {
    if (_cancelToken.isCancelled) {
      _cancelToken = CancelToken();
    }
  }

  @override
  void cancelActiveRequests() {
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('library sync cancelled');
    }
  }

  @override
  Future<List<Artist>> getArtists() =>
      _api.getArtists(cancelToken: _cancelToken);

  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) =>
      _api.getArtist(
        id,
        cancelToken: _cancelToken,
        maxResponseBytes: maxResponseBytes,
      );

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) => _api.getAlbum(
    id,
    cancelToken: _cancelToken,
    maxResponseBytes: maxResponseBytes,
  );

  @override
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) =>
      _api.getPlaylist(
        id,
        cancelToken: _cancelToken,
        maxResponseBytes: maxResponseBytes,
      );

  @override
  Future<StarredContent> getStarredContent() =>
      _api.getStarred2(cancelToken: _cancelToken);

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
      cancelToken: _cancelToken,
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
      cancelToken: _cancelToken,
    );
  }

  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return _api.getAlbumList2(
      type: 'newest',
      size: size,
      offset: offset,
      cancelToken: _cancelToken,
    );
  }

  @override
  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  }) => _api.getIndexes(
    ifModifiedSince: ifModifiedSince,
    cancelToken: _cancelToken,
    disableRetry: disableRetry,
  );

  @override
  Future<List<Playlist>> getPlaylists() =>
      _api.getPlaylists(cancelToken: _cancelToken);
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
const _compatibilityArtistVerificationLimit = 24;
const _newestAlbumHealthProbePageSize = 100;
const _manualNewestAlbumHealthProbeMaxPages = 5;
const _meteredManualNewestAlbumHealthProbePageSize = 50;
const _meteredManualAlbumHydrationLimit = 3;

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
    required this.newestRanks,
  });

  final Set<String> artistIds;
  final List<Album> discrepantAlbums;
  final Map<String, int> newestRanks;
}

class DriftLibrarySyncEngine extends LibrarySyncEngine
    implements TargetedLibrarySyncExecutor {
  DriftLibrarySyncEngine({
    required LibrarySyncApi api,
    required NavisDatabase database,
    required ServerConfigRepository serverConfigRepository,
    this.networkType = NetworkType.other,
    SyncNetworkPolicy Function()? readSyncNetworkPolicy,
    int? Function()? readMeteredResponseBudgetBytes,
    this.staleAfter = const Duration(hours: 1),
    this.auxiliarySyncStaleAfter = _defaultAuxiliarySyncStaleAfter,
    this.fastPathPageSize = 500,
    this.fastPathMaxPages = 200,
    this.bulkSearchPageSize = 1000,
    this.bulkSearchMaxPages = 200,
    this.bulkSearchProbeQueries = const <String>[''],
    this.fallbackArtistConcurrency = 4,
    this.wifiAlbumConcurrency = 2,
    this.cellularAlbumConcurrency = 1,
    this.otherAlbumConcurrency = 2,
    this.wifiMaxAlbumConcurrency = 8,
    this.cellularMaxAlbumConcurrency = 1,
    this.otherMaxAlbumConcurrency = 4,
    this.wifiFullCatalogAlbumConcurrency = 8,
    this.wifiFullCatalogMaxAlbumConcurrency = 24,
    this.otherFullCatalogAlbumConcurrency = 4,
    this.otherFullCatalogMaxAlbumConcurrency = 12,
    this.writeChunkSize = 48,
    this.isolateThreshold = 100,
    this.onBeforeSongIdentityRemap,
    this.readActiveSongId,
    this.readProtectedSongIds,
  }) : _api = api,
       _database = database,
       _serverConfigRepository = serverConfigRepository,
       _readSyncNetworkPolicy = readSyncNetworkPolicy,
       _readMeteredResponseBudgetBytes = readMeteredResponseBudgetBytes;

  final LibrarySyncApi _api;
  final NavisDatabase _database;
  final ServerConfigRepository _serverConfigRepository;
  final SyncNetworkPolicy Function()? _readSyncNetworkPolicy;
  final int? Function()? _readMeteredResponseBudgetBytes;
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
  final int wifiFullCatalogAlbumConcurrency;
  final int wifiFullCatalogMaxAlbumConcurrency;
  final int otherFullCatalogAlbumConcurrency;
  final int otherFullCatalogMaxAlbumConcurrency;
  final int writeChunkSize;
  final int isolateThreshold;
  final Future<void> Function(Map<String, String> aliases)?
  onBeforeSongIdentityRemap;
  final String? Function()? readActiveSongId;
  final Set<String> Function()? readProtectedSongIds;

  Future<LibrarySyncState>? _inFlight;
  bool _cancelled = false;
  SyncExecutionPlan? _activeExecutionPlan;
  Map<String, int> lastEndpointRequestCounts = const <String, int>{};

  /// Cancel any in-progress sync. Durable orchestration retains the work.
  void cancelSync() {
    _cancelled = true;
    _api.cancelActiveRequests();
  }

  Future<void> cancelAndWait() async {
    cancelSync();
    final running = _inFlight;
    if (running != null) {
      await running;
    }
  }

  /// Throws [SyncCancelledException] if [cancelSync] has been called.
  void _checkCancelled() {
    if (_cancelled) {
      throw const SyncCancelledException();
    }
  }

  void _ensureBackgroundWorkAllowed() {
    final policy = _currentSyncPolicy;
    if (policy.allowsBackgroundSync ||
        _allowsBroadMeteredWork ||
        _allowsLimitedMeteredManualDiscovery(manual: true)) {
      return;
    }
    _api.cancelActiveRequests();
    throw const SyncNetworkDeferredException();
  }

  bool get _allowsBroadMeteredWork =>
      _activeExecutionPlan?.request.networkGrant ==
      SyncNetworkGrant.broadMeteredOnce;

  bool _allowsLimitedMeteredManualDiscovery({required bool manual}) {
    final plan = _activeExecutionPlan;
    return manual &&
        _currentSyncPolicy.isMetered &&
        plan?.kind == SyncExecutionPlanKind.manualCatalogDiscovery &&
        plan?.request.networkGrant == SyncNetworkGrant.boundedMeteredDiscovery;
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
    if (readActiveSongId?.call() != null) {
      return 2;
    }
    return switch (networkType) {
      NetworkType.wifi => wifiMaxAlbumConcurrency,
      NetworkType.cellular => cellularMaxAlbumConcurrency,
      NetworkType.offline => 2,
      NetworkType.other => otherMaxAlbumConcurrency,
    };
  }

  int get _fullCatalogAlbumConcurrency {
    if (readActiveSongId?.call() != null) {
      return switch (networkType) {
        NetworkType.wifi => 4,
        NetworkType.cellular => cellularAlbumConcurrency,
        NetworkType.offline => 2,
        NetworkType.other => 2,
      };
    }
    return switch (networkType) {
      NetworkType.wifi => wifiFullCatalogAlbumConcurrency,
      NetworkType.cellular => cellularAlbumConcurrency,
      NetworkType.offline => 2,
      NetworkType.other => otherFullCatalogAlbumConcurrency,
    };
  }

  int get _fullCatalogMaxHydrationConcurrency {
    if (readActiveSongId?.call() != null) {
      return switch (networkType) {
        NetworkType.wifi => 8,
        NetworkType.cellular => cellularMaxAlbumConcurrency,
        NetworkType.offline => 2,
        NetworkType.other => 4,
      };
    }
    return switch (networkType) {
      NetworkType.wifi => wifiFullCatalogMaxAlbumConcurrency,
      NetworkType.cellular => cellularMaxAlbumConcurrency,
      NetworkType.offline => 2,
      NetworkType.other => otherFullCatalogMaxAlbumConcurrency,
    };
  }

  @override
  Future<LibrarySyncState> hydrateAlbum(
    String albumId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = albumId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    _cancelled = false;
    _api.beginRun();
    final startedAt = DateTime.now();
    final metrics = _SyncRunMetrics();
    var failureEndpoint = 'getAlbum';
    var state = LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingSongs,
      mode: LibrarySyncMode.incremental,
      startedAt: startedAt,
      metadataReady: true,
      isHydrating: true,
      processed: 0,
      total: 1,
      pendingHydrationCount: 1,
    );
    onProgress?.call(state);
    try {
      // Album detail is content authority, not catalog-membership authority.
      // Preserve an already-known remote tree before inspecting a detail
      // response that may omit or contradict its external provenance.
      final existingAlbum = await _database.libraryDao.getAlbumById(
        normalizedId,
      );
      final preserveExternalTree = existingAlbum?.isExternal ?? false;
      final budget = _meteredInteractionBudget();
      final maxBytes =
          budget?.nextMaxResponseBytes() ?? _meteredResponseBudgetBytes();
      final response = await _withRetry(
        () => _api.getAlbum(normalizedId, maxResponseBytes: maxBytes),
        metrics: metrics,
        endpoint: 'getAlbum',
      );
      final isExternalDetail =
          preserveExternalTree ||
          isExternalCatalogSource(
            id: response.id,
            apiIsExternal: response.isExternal,
          );
      final detail = isExternalDetail
          ? response
          : canonicalAlbumSnapshot(response, requestedId: normalizedId);
      if (isExternalDetail) {
        validateAlbumSnapshot(
          preserveExternalTree ? detail.copyWith(isExternal: true) : detail,
          requestedId: normalizedId,
        );
      }
      final externalReferences = isExternalDetail
          ? <Song>[]
          : response.songs
                .where((song) => song.isExternal == true)
                .toList(growable: false);
      final existingSongs = await _database.libraryDao
          .watchSongsByAlbum(normalizedId)
          .first;
      final incompleteEmptyResponse =
          detail.songs.isEmpty &&
          (((response.songCount ?? 0) > 0 && response.songs.isEmpty) ||
              (response.songCount == null && existingSongs.isNotEmpty));
      if (incompleteEmptyResponse) {
        state = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            isHydrating: false,
            pendingHydrationCount: 1,
            errorMessage: 'Album details were incomplete; existing tracks were preserved.',
          ),
          metrics,
        );
        onProgress?.call(state);
        return state;
      }
      final artistId = detail.artistId?.trim();
      ArtistsTableCompanion? missingArtist;
      final validArtistIds = await _database.libraryDao.getArtistIds();
      if (artistId != null && artistId.isNotEmpty) {
        if (!validArtistIds.contains(artistId)) {
          missingArtist = ArtistsTableCompanion.insert(
            id: artistId,
            name: detail.artist ?? 'Unknown Artist',
            isExternal: Value(isExternalDetail),
          );
          validArtistIds.add(artistId);
        }
      }
      final songs = await _toSongCompanions(
        detail.songs,
        defaultAlbumId: normalizedId,
        validArtistIds: validArtistIds,
        inheritExternalWhenMissing: isExternalDetail,
      );
      final provenanceSafeSongs = preserveExternalTree
          ? songs
                .map(
                  (song) => song.copyWith(
                    isExternal: const Value(true),
                    isProvisional: const Value(true),
                  ),
                )
                .toList(growable: false)
          : songs;
      final sameIdProvisionalSongs = (await _database.libraryDao.getSongsByIds(
        songs.map((song) => song.id.value),
      )).where((song) => song.isProvisional).map((song) => song.id).toSet();
      var albumMetadata = await _toAlbumCompanions(
        <Album>[detail],
        pendingHydrationAlbumIds: <String>[normalizedId],
        inheritExternalWhenMissing: isExternalDetail,
      );
      if (preserveExternalTree && existingAlbum != null) {
        albumMetadata = albumMetadata
            .map(
              (album) => album.copyWith(
                artistId: existingAlbum.artistId?.trim().isNotEmpty == true
                    ? Value(existingAlbum.artistId)
                    : album.artistId,
                artistName: existingAlbum.artistName?.trim().isNotEmpty == true
                    ? Value(existingAlbum.artistName)
                    : album.artistName,
                artists: existingAlbum.artists.isNotEmpty
                    ? Value(existingAlbum.artists)
                    : album.artists,
                isExternal: const Value(true),
                isProvisional: const Value(true),
              ),
            )
            .toList(growable: false);
      }
      final deferredCacheFiles = <String>[];
      failureEndpoint = 'writeAlbum';
      await _database.transaction(() async {
        if (externalReferences.isNotEmpty) {
          final referenceArtistIds = await _ensureReferenceParents(
            songs: externalReferences,
            snapshotStartedAt: startedAt,
          );
          await _database.libraryDao.upsertProvisionalSongs(
            await _toSongCompanions(
              externalReferences,
              validArtistIds: referenceArtistIds,
            ),
            snapshotStartedAt: startedAt,
          );
        }
        if (missingArtist != null) {
          if (isExternalDetail) {
            await _database.libraryDao.upsertProvisionalArtists([
              missingArtist,
            ]);
          } else {
            await _database.libraryDao.upsertArtists([missingArtist]);
          }
        }
        if (isExternalDetail) {
          if (preserveExternalTree) {
            await _database.libraryDao.markAlbumsExternalAndProvisional([
              normalizedId,
            ]);
          }
          await _database.libraryDao.upsertProvisionalAlbums(
            albumMetadata,
            snapshotStartedAt: startedAt,
          );
          await _database.libraryDao.upsertProvisionalSongs(
            provenanceSafeSongs,
            snapshotStartedAt: startedAt,
          );
          await _database.libraryDao.markAlbumSongsHydrated(normalizedId);
        } else {
          await _database.libraryDao.reconcileSongsForAlbumsChunk(
            <String, List<SongsTableCompanion>>{normalizedId: songs},
            markAlbumsHydrated: true,
            albumMetadata: albumMetadata,
            snapshotStartedAt: startedAt,
            deferredCacheFiles: deferredCacheFiles,
            serverId: (await _serverConfigRepository.getActiveServer())?.id,
          );
          failureEndpoint = 'reconcileSongIdentity';
          await _reconcileHydratedSongIds(
            canonicalSongIds: songs
                .where((song) => song.id.present)
                .map((song) => song.id.value),
            sameIdProvisionalSongs: sameIdProvisionalSongs,
            metrics: metrics,
          );
        }
      });
      await _database.libraryDao.cleanupRemovedCacheFiles(deferredCacheFiles);
      metrics.addDbWriteBatch();
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          processed: 1,
          pendingHydrationCount: 0,
        ),
        metrics,
      );
    } on SyncCancelledException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: 'Sync cancelled.',
        ),
        metrics,
      );
    } on SyncNetworkDeferredException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: 'Sync deferred by network policy.',
        ),
        metrics,
      );
    } on SubsonicResponseBudgetExceededException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          pendingHydrationCount: 1,
          errorMessage:
              'Sync deferred: response exceeded the mobile-data budget.',
        ),
        metrics,
      );
    } on SubsonicIncompleteResponseException catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          pendingHydrationCount: 1,
          errorMessage: error.message,
        ),
        metrics,
      );
    } on Object catch (error) {
      metrics.recordFailureDiagnostic(
        stage: state.stage.name,
        endpoint: failureEndpoint,
        entityId: normalizedId,
        error: error,
        attempts: metrics.apiRequests,
      );
      await _persistFailureDiagnosticsBestEffort(
        metrics,
        clearWhenEmpty: false,
      );
      state = _withMetrics(
        state.copyWith(
          status: _cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: _cancelled
              ? 'Sync cancelled.'
              : _toSafeErrorMessage(error),
        ),
        metrics,
      );
    }
    onProgress?.call(state);
    return state;
  }

  @override
  Future<LibrarySyncState> hydrateArtist(
    String artistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = artistId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    _cancelled = false;
    _api.beginRun();
    final startedAt = DateTime.now();
    final metrics = _SyncRunMetrics();
    var state = LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingAlbums,
      mode: LibrarySyncMode.incremental,
      startedAt: startedAt,
      metadataReady: true,
      isHydrating: true,
      total: 1,
    );
    onProgress?.call(state);
    try {
      final budget = _meteredInteractionBudget();
      final maxBytes =
          budget?.nextMaxResponseBytes() ?? _meteredResponseBudgetBytes();
      final detail = await _withRetry(
        () => _api.getArtist(normalizedId, maxResponseBytes: maxBytes),
        metrics: metrics,
        endpoint: 'getArtist',
      );
      final isExternalDetail = isExternalCatalogSource(
        id: detail.id,
        apiIsExternal: detail.isExternal,
      );
      if (detail.albums.isEmpty && (detail.albumCount ?? 0) > 0) {
        state = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            isHydrating: false,
            errorMessage: 'Artist details were incomplete; existing albums were preserved.',
          ),
          metrics,
        );
        onProgress?.call(state);
        return state;
      }
      await _database.transaction(() async {
        final artistRows = <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(
            id: detail.id,
            name: detail.name,
            albumCount: Value(detail.albumCount),
            coverArt: Value(detail.coverArt),
            starred: Value(detail.starred),
            isExternal: Value(isExternalDetail),
          ),
        ];
        final albumRows = await _toAlbumCompanions(
          detail.albums,
          pendingHydrationAlbumIds: detail.albums.map((album) => album.id),
          inheritExternalWhenMissing: isExternalDetail,
        );
        final externalAlbumRows = albumRows
            .where(
              (album) => album.isExternal.present && album.isExternal.value,
            )
            .toList(growable: false);
        final localAlbumRows = albumRows
            .where(
              (album) => !album.isExternal.present || !album.isExternal.value,
            )
            .toList(growable: false);
        if (isExternalDetail) {
          await _database.libraryDao.upsertProvisionalArtists(
            artistRows,
            snapshotStartedAt: startedAt,
          );
          await _database.libraryDao.upsertProvisionalAlbums(
            albumRows,
            snapshotStartedAt: startedAt,
          );
        } else {
          await _database.libraryDao.upsertArtists(
            artistRows,
            snapshotStartedAt: startedAt,
          );
          // An otherwise local artist can contain releases from a remote
          // catalogue. Keep those rows provisional: artist pages deliberately
          // show them, while the main Albums library remains server-only.
          await _database.libraryDao.upsertAlbums(
            localAlbumRows,
            snapshotStartedAt: startedAt,
          );
          await _database.libraryDao.markAlbumsExternalAndProvisional(
            externalAlbumRows
                .where((album) => album.id.present)
                .map((album) => album.id.value),
          );
          await _database.libraryDao.upsertProvisionalAlbums(
            externalAlbumRows,
            snapshotStartedAt: startedAt,
          );
        }
      });
      metrics.addDbWriteBatch();
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          processed: 1,
        ),
        metrics,
      );
    } on SyncCancelledException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: 'Sync cancelled.',
        ),
        metrics,
      );
    } on SyncNetworkDeferredException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: 'Sync deferred by network policy.',
        ),
        metrics,
      );
    } on SubsonicResponseBudgetExceededException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage:
              'Sync deferred: response exceeded the mobile-data budget.',
        ),
        metrics,
      );
    } on Object catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: _cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: _cancelled
              ? 'Sync cancelled.'
              : _toSafeErrorMessage(error),
        ),
        metrics,
      );
    }
    onProgress?.call(state);
    return state;
  }

  @override
  Future<LibrarySyncState> hydratePlaylist(
    String playlistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = playlistId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    _cancelled = false;
    _api.beginRun();
    final startedAt = DateTime.now();
    final metrics = _SyncRunMetrics();
    var state = LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingSongs,
      mode: LibrarySyncMode.incremental,
      startedAt: startedAt,
      metadataReady: true,
      isHydrating: true,
      total: 1,
    );
    onProgress?.call(state);
    try {
      final budget = _meteredInteractionBudget();
      final maxBytes =
          budget?.nextMaxResponseBytes() ?? _meteredResponseBudgetBytes();
      final playlist = await _withRetry(
        () => _api.getPlaylist(normalizedId, maxResponseBytes: maxBytes),
        metrics: metrics,
        endpoint: 'getPlaylist',
      );
      validatePlaylistSnapshot(playlist, requestedId: normalizedId);
      final existingSongs = await _database.playlistDao
          .watchPlaylistSongs(normalizedId)
          .first;
      if (playlist.entries.isEmpty &&
          (playlist.songCount ?? existingSongs.length) > 0) {
        state = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.partial,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            isHydrating: false,
            errorMessage: 'Playlist details were incomplete; existing tracks were preserved.',
          ),
          metrics,
        );
        onProgress?.call(state);
        return state;
      }
      await _database.transaction(() async {
        final validArtistIds = await _ensureReferenceParents(
          songs: playlist.entries,
          snapshotStartedAt: startedAt,
        );
        final songs = await _toSongCompanions(
          playlist.entries,
          validArtistIds: validArtistIds,
        );
        final sameIdProvisionalSongs =
            (await _database.libraryDao.getSongsByIds(
                  songs.map((song) => song.id.value),
                ))
                .where((song) => song.isProvisional)
                .map((song) => song.id)
                .toSet();
        await _database.playlistDao.replaceHydratedPlaylist(
          PlaylistsTableCompanion.insert(
            id: playlist.id,
            name: playlist.name,
            songCount: Value(playlist.songCount),
            duration: Value(playlist.duration),
            owner: Value(playlist.owner),
            isPublic: Value(playlist.isPublic),
            coverArt: Value(playlist.coverArt),
            comment: Value(playlist.comment),
          ),
          songs,
          <PlaylistSongsTableCompanion>[
            for (var index = 0; index < playlist.entries.length; index++)
              PlaylistSongsTableCompanion.insert(
                playlistId: normalizedId,
                songId: playlist.entries[index].id,
                sortOrder: index,
              ),
          ],
          snapshotStartedAt: startedAt,
        );
        metrics.addDbWriteBatch();
        await _reconcileHydratedSongIds(
          canonicalSongIds: playlist.entries.map((song) => song.id),
          sameIdProvisionalSongs: sameIdProvisionalSongs,
          metrics: metrics,
        );
      });
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          processed: 1,
        ),
        metrics,
      );
    } on SyncCancelledException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: 'Sync cancelled.',
        ),
        metrics,
      );
    } on SyncNetworkDeferredException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: 'Sync deferred by network policy.',
        ),
        metrics,
      );
    } on SubsonicResponseBudgetExceededException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.deferred,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage:
              'Sync deferred: response exceeded the mobile-data budget.',
        ),
        metrics,
      );
    } on SubsonicIncompleteResponseException catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.partial,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          pendingHydrationCount: 1,
          errorMessage: error.message,
        ),
        metrics,
      );
    } on Object catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: _cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          isHydrating: false,
          errorMessage: _cancelled
              ? 'Sync cancelled.'
              : _toSafeErrorMessage(error),
        ),
        metrics,
      );
    }
    onProgress?.call(state);
    return state;
  }

  @override
  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runAuxiliaryTarget(
      stage: LibrarySyncStage.fetchingStarred,
      operation: _syncStarredContentStrict,
      onProgress: onProgress,
    );
  }

  @override
  Future<LibrarySyncState> syncPlaylistHeaders({
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runAuxiliaryTarget(
      stage: LibrarySyncStage.fetchingPlaylists,
      operation: _syncPlaylistHeadersStrict,
      onProgress: onProgress,
    );
  }

  Future<LibrarySyncState> _runAuxiliaryTarget({
    required LibrarySyncStage stage,
    required Future<void> Function(_SyncRunMetrics metrics) operation,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    _cancelled = false;
    _api.beginRun();
    final startedAt = DateTime.now();
    final metrics = _SyncRunMetrics();
    var state = LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: stage,
      mode: LibrarySyncMode.incremental,
      startedAt: startedAt,
      metadataReady: true,
    );
    onProgress?.call(state);
    try {
      await operation(metrics);
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
        ),
        metrics,
      );
    } on SyncCancelledException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: 'Sync cancelled.',
        ),
        metrics,
      );
    } on Object catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: _cancelled
              ? LibrarySyncStatus.cancelled
              : LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: _cancelled
              ? 'Sync cancelled.'
              : _toSafeErrorMessage(error),
        ),
        metrics,
      );
    }
    onProgress?.call(state);
    return state;
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

  Future<LibrarySyncState> runCompatibilityAudit({
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runWithLock(
      force: true,
      forceFull: false,
      manual: false,
      verificationContinuation: false,
      compatibilityAudit: true,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
  }

  /// Typed scheduler entrypoint. Policy-sensitive broad execution receives the
  /// immutable plan selected at admission time; the public methods above are
  /// retained only as compatibility adapters for older callers.
  Future<LibrarySyncState> executeSyncExecutionPlan(
    SyncExecutionPlan plan, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    final target = plan.request.target;
    return switch (plan.kind) {
      SyncExecutionPlanKind.automaticProbe => probeCatalog(
        onProgress: onProgress,
      ),
      SyncExecutionPlanKind.manualCatalogDiscovery => _runWithLock(
        force: true,
        forceFull: false,
        manual: plan.request.intent == SyncRunIntent.manualCatalogCheck,
        verificationContinuation: false,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
        executionPlan: plan,
      ),
      SyncExecutionPlanKind.repairLibrary ||
      SyncExecutionPlanKind.catalogSnapshot => _runWithLock(
        force: true,
        forceFull: true,
        manual: true,
        verificationContinuation: false,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
        executionPlan: plan,
      ),
      SyncExecutionPlanKind.compatibilityAudit => _runWithLock(
        force: true,
        forceFull: false,
        manual: false,
        verificationContinuation: false,
        compatibilityAudit: true,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
        executionPlan: plan,
      ),
      SyncExecutionPlanKind.targetHydration ||
      SyncExecutionPlanKind.auxiliaryRefresh => switch (target.kind) {
        LibrarySyncTargetKind.album when target.entityId != null =>
          hydrateAlbum(target.entityId!, onProgress: onProgress),
        LibrarySyncTargetKind.artist when target.entityId != null =>
          hydrateArtist(target.entityId!, onProgress: onProgress),
        LibrarySyncTargetKind.playlist when target.entityId != null =>
          hydratePlaylist(target.entityId!, onProgress: onProgress),
        LibrarySyncTargetKind.playlistHeaders => syncPlaylistHeaders(
          onProgress: onProgress,
        ),
        LibrarySyncTargetKind.starred => syncStarredContent(
          onProgress: onProgress,
        ),
        LibrarySyncTargetKind.genres => _genresSyncDisabled(
          onProgress: onProgress,
        ),
        _ => _runWithLock(
          force: true,
          forceFull: false,
          manual: false,
          verificationContinuation: true,
          executionPlan: plan,
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        ),
      },
    };
  }

  @override
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) async {
    _cancelled = false;
    _api.beginRun();
    final startedAt = DateTime.now();
    final metrics = _SyncRunMetrics();
    var state = LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingArtists,
      mode: LibrarySyncMode.incremental,
      planKind: LibrarySyncPlanKind.probe,
      planReason: 'hardCatalogProbe',
      startedAt: startedAt,
      metadataReady: true,
    );
    onProgress?.call(state);

    try {
      final serverConfig = await _serverConfigRepository.getActiveServer();
      if (serverConfig == null) {
        state = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.failed,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            errorMessage: 'No active server.',
          ),
          metrics,
        );
        onProgress?.call(state);
        return state;
      }

      final committedCursor = _readNavisDateCapability(
        serverConfig.capabilitiesJson,
        _libraryIndexesCursorCapabilityKey,
      );
      Indexes? indexes;
      var indexesUnsupported = false;
      var indexChanged = false;
      try {
        // Hard probe: one conditional request, no engine or HTTP retries.
        indexes = await _api.getIndexes(
          ifModifiedSince: committedCursor,
          disableRetry: true,
        );
        metrics.recordApiAttempt(
          elapsed: Duration.zero,
          isRetryAttempt: false,
          endpoint: 'getIndexes',
        );
        final targetCursor = indexes.lastModified;
        if (targetCursor == null ||
            (committedCursor != null &&
                targetCursor.isBefore(committedCursor))) {
          indexesUnsupported = true;
        } else if (committedCursor == null ||
            targetCursor.isAfter(committedCursor)) {
          indexChanged = true;
        }
      } on Object catch (error) {
        metrics.recordApiAttempt(
          elapsed: Duration.zero,
          isRetryAttempt: false,
          endpoint: 'getIndexes',
        );
        if (!_isIndexesUnsupported(error)) {
          rethrow;
        }
        indexesUnsupported = true;
      }

      // Scan-aware admission rides the existing scheduled probe: a newly
      // completed server scan opens one resumable snapshot through the same
      // coordinator path as an index change. No separate polling loop.
      final scanChanged = await _observeScanStatusAndDetectChange(
        serverId: serverConfig.id!,
        metrics: metrics,
      );
      if (scanChanged) {
        indexChanged = true;
      }

      // Never advance the committed cursor from a probe. Evidence is returned
      // so the coordinator can enqueue follow-up background work.
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.succeeded,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          probeIndexChanged: indexChanged,
          probeEvidenceVersion: indexes == null
              ? 'indexesUnsupported'
              : sha256
                    .convert(
                      utf8.encode(
                        '${indexes.lastModified?.toUtc().toIso8601String()}:${_fingerprintIndexes(indexes)}',
                      ),
                    )
                    .toString(),
          probeIndexesUnsupported: indexesUnsupported,
          updatesAvailable: indexChanged || indexesUnsupported,
          lastCheckedAt: DateTime.now(),
        ),
        metrics,
      );
      onProgress?.call(state);
      return state;
    } on SyncCancelledException {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.cancelled,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: 'Sync cancelled.',
        ),
        metrics,
      );
      onProgress?.call(state);
      return state;
    } on Object catch (error) {
      state = _withMetrics(
        state.copyWith(
          status: LibrarySyncStatus.failed,
          stage: LibrarySyncStage.completed,
          completedAt: DateTime.now(),
          errorMessage: _toSafeErrorMessage(error),
        ),
        metrics,
      );
      onProgress?.call(state);
      return state;
    }
  }

  SyncNetworkPolicy get _currentSyncPolicy {
    final reader = _readSyncNetworkPolicy;
    if (reader != null) {
      return reader();
    }
    return resolveSyncNetworkPolicy(
      networkType: networkType,
      nativeMetered: networkType == NetworkType.cellular ? true : false,
      backgroundSyncUnmeteredOnly: true,
    );
  }

  int? _meteredResponseBudgetBytes() {
    if (!_currentSyncPolicy.isMetered) {
      return null;
    }
    final override = _readMeteredResponseBudgetBytes?.call();
    if (override != null) {
      return override;
    }
    return kMeteredSyncMaxResponseBytes;
  }

  _MeteredInteractionBudget? _meteredInteractionBudget() {
    if (!_currentSyncPolicy.isMetered) {
      return null;
    }
    final override = _readMeteredResponseBudgetBytes?.call();
    final maxResponse = override ?? kMeteredSyncMaxResponseBytes;
    return _MeteredInteractionBudget(
      maxResponseBytes: maxResponse,
      maxInteractionBytes: override == null
          ? kMeteredSyncMaxInteractionBytes
          : (override * 2),
    );
  }

  Future<LibrarySyncState> _runWithLock({
    required bool force,
    required bool forceFull,
    required bool manual,
    required bool verificationContinuation,
    bool compatibilityAudit = false,
    SyncExecutionPlan? executionPlan,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) {
    final running = _inFlight;
    if (running != null) {
      return running;
    }

    _cancelled = false;
    _api.beginRun();
    _activeExecutionPlan = executionPlan;
    final future = _runSync(
      force: force,
      forceFull: forceFull,
      manual: manual,
      verificationContinuation: verificationContinuation,
      compatibilityAudit: compatibilityAudit,
      priorityAlbumIds: priorityAlbumIds,
      onProgress: onProgress,
    );
    _inFlight = future;
    return future.whenComplete(() {
      _inFlight = null;
      _cancelled = false;
      if (identical(_activeExecutionPlan, executionPlan)) {
        _activeExecutionPlan = null;
      }
    });
  }

  Future<LibrarySyncState> _runSync({
    required bool force,
    required bool forceFull,
    required bool manual,
    required bool verificationContinuation,
    required bool compatibilityAudit,
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
      _ensureBackgroundWorkAllowed();
      final auxiliaryDue = _shouldSyncAuxiliary(serverConfig.capabilitiesJson);
      // Typed catalog operations never absorb starred, playlist-header, or
      // genre refreshes. Those are their own auxiliary targets. Legacy entry
      // points retain the previous combined behavior for one release.
      final syncAuxiliary =
          _activeExecutionPlan == null && (manual || auxiliaryDue);
      if (pendingHydrationCount > 0 &&
          ((verificationContinuation && pendingArtistVerificationCount == 0) ||
              (!force && hasFreshSync))) {
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
          compatibilityAudit: compatibilityAudit,
          metrics: metrics,
          onProgress: onProgress,
        );
      } else {
        state = await _runFullSync(
          state: state,
          serverConfig: serverConfig,
          mode: mode,
          priorityAlbumIds: priorityAlbumIds,
          syncAuxiliary: syncAuxiliary,
          metrics: metrics,
          onProgress: onProgress,
        );
      }

      final catalogWasPromoted =
          state.mode == LibrarySyncMode.fullInitial ||
          state.mode == LibrarySyncMode.forceFull;
      if (!catalogWasPromoted) {
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
      }

      if (syncAuxiliary &&
          (manual ||
              (metrics.metadataChanged && !metrics.verificationContinuation) ||
              auxiliaryDue)) {
        await _reconcileStarredContent(metrics);
        if (metrics.starredSynchronized &&
            metrics.playlistHeadersSynchronized) {
          await _markAuxiliarySynced(DateTime.now(), metrics);
        }
      } else {
        metrics.skippedReason = metrics.skippedReason ?? 'auxiliaryFresh';
      }

      final pendingAlbums =
          state.pendingHydrationCount ??
          await _database.libraryDao.countPendingHydrationAlbums();
      final incompleteAlbumIds = metrics.incompleteAlbumIds;
      final onlyIncompleteAlbumDetails =
          pendingAlbums > 0 &&
          pendingAlbums == incompleteAlbumIds.length &&
          (await _database.libraryDao.getPendingHydrationAlbumIds())
              .toSet()
              .containsAll(incompleteAlbumIds);
      await _persistFailureDiagnosticsBestEffort(
        metrics,
        clearWhenEmpty:
            state.freshness == LibrarySyncFreshness.current &&
            state.remainingVerificationCount == 0 &&
            pendingAlbums == 0,
      );

      final syncedAt = DateTime.now();
      final completedMode = state.mode ?? mode;
      final fullyCurrent =
          pendingAlbums == 0 &&
          state.remainingVerificationCount == 0 &&
          state.candidateGeneration == null &&
          state.candidateStatus == null;
      if (fullyCurrent && completedMode == LibrarySyncMode.incremental) {
        await _serverConfigRepository.updateLastSynced(syncedAt);
        metrics.addDbWriteBatch();
      } else if (fullyCurrent) {
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
          lastSyncedAt: fullyCurrent ? syncedAt : serverConfig.lastSynced,
          onlyIncompleteAlbumDetails: onlyIncompleteAlbumDetails,
        ),
        metrics,
      );
      onProgress?.call(succeeded);
      _logSyncSummary(state: succeeded, metrics: metrics);
      return succeeded;
    } on Object catch (error, stackTrace) {
      if (error is SyncNetworkDeferredException ||
          error is SubsonicSyncLimitException ||
          error is SubsonicResponseBudgetExceededException) {
        final deferredConfig = await _serverConfigRepository.getActiveServer();
        final deferredArtists = _readPendingArtistIds(
          deferredConfig?.capabilitiesJson,
        );
        final deferredOffset = _readNavisIntCapability(
          deferredConfig?.capabilitiesJson,
          _libraryPendingOffsetCapabilityKey,
        ).clamp(0, deferredArtists.length);
        final deferred = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.deferred,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            pendingHydrationCount: await _database.libraryDao
                .countPendingHydrationAlbums(),
            remainingVerificationCount: deferredArtists.length - deferredOffset,
            errorMessage: _toSafeErrorMessage(error),
          ),
          metrics,
        );
        onProgress?.call(deferred);
        _logSyncSummary(state: deferred, metrics: metrics);
        return deferred;
      }
      if (_cancelled) {
        final cancelled = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.cancelled,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            errorMessage: 'Sync cancelled.',
          ),
          metrics,
        );
        onProgress?.call(cancelled);
        return cancelled;
      }
      // Earlier entity failures must not hide the error which terminated the
      // operation (for example, a promotion or ownership failure).
      metrics.recordFailureDiagnostic(
        stage: state.stage.name,
        endpoint: 'sync',
        entityId: 'sync',
        error: error,
        attempts: 1,
      );
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
        final failed = _withMetrics(
          state.copyWith(
            status: LibrarySyncStatus.failed,
            failureCategory: 'transport',
            nextRetryAt: error is SubsonicApiException ? error.retryAt : null,
            stage: LibrarySyncStage.completed,
            completedAt: DateTime.now(),
            errorMessage:
                'Server temporarily unavailable. Sync will retry later.',
          ),
          metrics,
        );
        onProgress?.call(failed);
        _logSyncSummary(state: failed, metrics: metrics);
        return failed;
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

  /// Gets catalog artists while tolerating servers that only expose them in
  /// the standard `getIndexes` response.
  Future<List<Artist>> _loadCatalogArtists(_SyncRunMetrics metrics) async {
    try {
      return await _withRetry(
        _api.getArtists,
        metrics: metrics,
        endpoint: 'getArtists',
      );
    } on Object catch (getArtistsError) {
      if (!_isIndexesUnsupported(getArtistsError)) {
        rethrow;
      }

      try {
        final indexes = await _withRetry(
          _api.getIndexes,
          metrics: metrics,
          endpoint: 'getIndexes',
        );
        final artistsById = <String, Artist>{};
        void addAll(Iterable<Artist> candidates) {
          for (final artist in candidates) {
            artistsById.putIfAbsent(artist.id, () => artist);
          }
        }

        for (final index in indexes.indexes) {
          addAll(index.artists);
        }
        addAll(indexes.shortcut);
        addAll(indexes.child);
        return artistsById.values.toList(growable: false);
      } on Object catch (indexesError) {
        if (_isIndexesUnsupported(indexesError)) {
          AppLogger.info(
            'Artist-list endpoints unavailable; deriving artists from album pages.',
          );
          return const <Artist>[];
        }
        rethrow;
      }
    }
  }

  Future<void> _reconcileStarredContent(_SyncRunMetrics metrics) async {
    try {
      await _syncStarredContentStrict(metrics);
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

  Future<void> _syncStarredContentStrict(_SyncRunMetrics metrics) async {
    final snapshotStartedAt = DateTime.now();
    final starred = await _withRetry(
      _api.getStarredContent,
      metrics: metrics,
      endpoint: 'getStarredContent',
    );
    final albumStarredAt = <String, DateTime?>{
      for (final album in starred.albums)
        album.id: album.starred ?? snapshotStartedAt,
    };
    final artistStarredAt = <String, DateTime?>{
      for (final artist in starred.artists)
        artist.id: artist.starred ?? snapshotStartedAt,
    };
    final songStarredAt = <String, DateTime?>{
      for (final song in starred.songs)
        song.id: song.starred ?? snapshotStartedAt,
    };
    final serverConfig = await _serverConfigRepository.getActiveServer();
    final serverId = serverConfig?.id;

    await _database.transaction(() async {
      final pendingActions = await _database.starSyncDao.getPendingActions();
      final pendingByType = <String, Set<String>>{
        'album': <String>{},
        'artist': <String>{},
        'song': <String>{},
      };
      for (final action in pendingActions) {
        if (action.operation != 'star') continue;
        pendingByType[action.itemType]?.add(action.itemId);
      }
      final concurrentMutations = await _database.librarySyncDao
          .getLocalStarMutationsSince(snapshotStartedAt);
      for (final entry in concurrentMutations.entries) {
        pendingByType[entry.key]?.addAll(entry.value);
      }

      // Starred snapshots are reference metadata, not catalog enumeration.
      // Materialize unseen favorites without promoting them into Library.
      await _database.libraryDao.upsertProvisionalArtists(
        _toArtistCompanions(starred.artists),
        snapshotStartedAt: snapshotStartedAt,
      );
      final referenceArtistIds = await _ensureReferenceParents(
        albums: starred.albums,
        songs: starred.songs,
        snapshotStartedAt: snapshotStartedAt,
      );
      await _database.libraryDao.upsertProvisionalAlbums(
        await _toAlbumCompanions(
          starred.albums,
          pendingHydrationAlbumIds: starred.albums.map((album) => album.id),
        ),
        snapshotStartedAt: snapshotStartedAt,
      );
      await _database.libraryDao.upsertProvisionalSongs(
        await _toSongCompanions(
          starred.songs,
          validArtistIds: referenceArtistIds,
        ),
        snapshotStartedAt: snapshotStartedAt,
      );
      final localAlbumIds = await _database.libraryDao.getStarredAlbumIds();
      final localArtistIds = await _database.libraryDao.getStarredArtistIds();
      final localSongIds = await _database.libraryDao.getStarredSongIds();
      final confirmedAbsentAlbumIds = await _confirmedStarredAbsences(
        serverId: serverId,
        entityType: 'album',
        localIds: localAlbumIds,
        serverIds: albumStarredAt.keys.toSet(),
        protectedIds: pendingByType['album']!,
      );
      final confirmedAbsentArtistIds = await _confirmedStarredAbsences(
        serverId: serverId,
        entityType: 'artist',
        localIds: localArtistIds,
        serverIds: artistStarredAt.keys.toSet(),
        protectedIds: pendingByType['artist']!,
      );
      final confirmedAbsentSongIds = await _confirmedStarredAbsences(
        serverId: serverId,
        entityType: 'song',
        localIds: localSongIds,
        serverIds: songStarredAt.keys.toSet(),
        protectedIds: pendingByType['song']!,
      );
      await _database.libraryDao.batchReconcileAlbumStarred(
        albumStarredAt,
        excludeIds: pendingByType['album']!,
        confirmedAbsentIds: confirmedAbsentAlbumIds,
      );
      await _database.libraryDao.batchReconcileArtistStarred(
        artistStarredAt,
        excludeIds: pendingByType['artist']!,
        confirmedAbsentIds: confirmedAbsentArtistIds,
      );
      await _database.libraryDao.batchReconcileSongStarred(
        songStarredAt,
        excludeIds: pendingByType['song']!,
        confirmedAbsentIds: confirmedAbsentSongIds,
      );
      final confirmedRemovalCount =
          confirmedAbsentAlbumIds.length +
          confirmedAbsentArtistIds.length +
          confirmedAbsentSongIds.length;
      if (serverId != null && confirmedRemovalCount > 0) {
        final afterAlbumIds = await _database.libraryDao.getStarredAlbumIds();
        final afterArtistIds = await _database.libraryDao.getStarredArtistIds();
        final afterSongIds = await _database.libraryDao.getStarredSongIds();
        await _database.librarySyncDao.recordOperationLedgerEntry(
          serverId: serverId,
          operation: 'starredReconciliation',
          reason: 'confirmedSecondAbsence',
          details: <String, Object?>{
            'before': <String, int>{
              'artists': localArtistIds.length,
              'albums': localAlbumIds.length,
              'songs': localSongIds.length,
            },
            'after': <String, int>{
              'artists': afterArtistIds.length,
              'albums': afterAlbumIds.length,
              'songs': afterSongIds.length,
            },
            'removed': <String, int>{
              'artists': confirmedAbsentArtistIds.length,
              'albums': confirmedAbsentAlbumIds.length,
              'songs': confirmedAbsentSongIds.length,
            },
          },
        );
      }
    });
    metrics
      ..addDbWriteBatch()
      ..starredSynchronized = true;
  }

  /// Referenced favorites and playlist entries may arrive before their parents.
  /// Store only the named parents, never enumerate an external discography.
  Future<Set<String>> _ensureReferenceParents({
    List<Album> albums = const [],
    required List<Song> songs,
    required DateTime snapshotStartedAt,
  }) async {
    final artists = <String, ArtistsTableCompanion>{};
    final albumRefs = <String, AlbumsTableCompanion>{};
    for (final album in albums) {
      final artistId = album.artistId?.trim();
      if (artistId != null && artistId.isNotEmpty) {
        artists[artistId] = ArtistsTableCompanion.insert(
          id: artistId,
          name: album.artist ?? 'Unknown Artist',
          isExternal: Value(isExternalCatalogSource(id: artistId)),
        );
      }
    }
    for (final song in songs) {
      final artistId = song.artistId?.trim();
      if (artistId != null && artistId.isNotEmpty) {
        artists.putIfAbsent(
          artistId,
          () => ArtistsTableCompanion.insert(
            id: artistId,
            name: song.artist ?? 'Unknown Artist',
            isExternal: Value(isExternalCatalogSource(id: artistId)),
          ),
        );
      }
      final albumId = song.albumId?.trim();
      if (albumId != null && albumId.isNotEmpty) {
        albumRefs.putIfAbsent(
          albumId,
          () => AlbumsTableCompanion.insert(
            id: albumId,
            name: song.album ?? 'Unknown Album',
            artistId: Value(artistId),
            artistName: Value(song.artist),
            songsHydrated: const Value(false),
            isExternal: Value(
              isExternalCatalogSource(
                id: albumId,
                apiIsExternal: song.isExternal,
              ),
            ),
          ),
        );
      }
    }
    final existingArtistIds = (await _database.libraryDao.getArtistsByIds(
      artists.keys,
    )).map((row) => row.id).toSet();
    await _database.libraryDao.upsertProvisionalArtists(
      artists.entries
          .where((entry) => !existingArtistIds.contains(entry.key))
          .map((entry) => entry.value)
          .toList(),
      snapshotStartedAt: snapshotStartedAt,
    );
    final existingAlbumIds = (await _database.libraryDao.getAlbumsByIds(
      albumRefs.keys,
    )).map((row) => row.id).toSet();
    await _database.libraryDao.upsertProvisionalAlbums(
      albumRefs.entries
          .where((entry) => !existingAlbumIds.contains(entry.key))
          .map((entry) => entry.value)
          .toList(),
      snapshotStartedAt: snapshotStartedAt,
    );
    return {...await _database.libraryDao.getArtistIds(), ...artists.keys};
  }

  Future<Set<String>> _confirmedStarredAbsences({
    required int? serverId,
    required String entityType,
    required Set<String> localIds,
    required Set<String> serverIds,
    required Set<String> protectedIds,
  }) async {
    if (serverId == null) {
      // A successful snapshot can still add stars without a durable server
      // identity, but it must never clear local data in that abnormal state.
      return const <String>{};
    }
    await _database.librarySyncDao.clearStarredAbsenceCandidates(
      serverId: serverId,
      entityType: entityType,
      ids: {...serverIds, ...protectedIds},
    );
    final absentIds = localIds.difference(serverIds).difference(protectedIds);
    return _database.librarySyncDao.observeStarredAbsences(
      serverId: serverId,
      entityType: entityType,
      ids: absentIds,
      observedAt: DateTime.now(),
    );
  }

  LibrarySyncMode _resolveMode(
    ServerConfigModel config, {
    required bool forceFull,
  }) {
    if (forceFull) {
      return LibrarySyncMode.forceFull;
    }

    // The coordinator can admit incremental continuation of a safely promoted
    // partial catalog before a full-completion timestamp exists. Do not widen
    // that immutable plan into an unbudgeted initial scan.
    if (_activeExecutionPlan != null) return LibrarySyncMode.incremental;
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
    _SyncRunMetrics metrics, {
    required bool manual,
  }) async {
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

    // `newest` is a direct discovery path, but servers can have a much larger
    // recent window than one response page. A manual check deliberately
    // scans a fixed 500-album window, independent of `getIndexes`; automatic
    // checks retain the original low-data one-page probe plus a look-ahead
    // only when that first page is entirely newer or unknown.
    final limitedMeteredManualDiscovery = _allowsLimitedMeteredManualDiscovery(
      manual: manual,
    );
    final maxPages =
        _activeExecutionPlan?.budget.maxNewestPages ??
        (limitedMeteredManualDiscovery
            ? 1
            : manual
            ? _manualNewestAlbumHealthProbeMaxPages
            : 2);
    final pageSize = limitedMeteredManualDiscovery
        ? _meteredManualNewestAlbumHealthProbePageSize
        : _newestAlbumHealthProbePageSize;
    final pages = <Album>[];
    final seenIds = <String>{};
    var offset = 0;
    for (var pageIndex = 0; pageIndex < maxPages; pageIndex++) {
      final page = await _withRetry(
        () => _api.getNewestAlbumListPage(
          size: pageSize,
          offset: offset,
        ),
        metrics: metrics,
        endpoint: 'getNewestAlbumList2',
      );
      if (page.isEmpty) break;
      if (page.any(
        (album) => album.id.trim().isEmpty || !seenIds.add(album.id),
      )) {
        throw const SubsonicIncompleteResponseException(
          'Newest feed repeated or returned invalid identities.',
        );
      }
      await _repairExternalSourceEvidence(albums: page);
      pages.addAll(page);
      offset += page.length;
      if (manual) {
        continue;
      }
      final firstPageEntirelyNewerOrUnknown = page.every((album) {
        if (!localById.containsKey(album.id)) {
          return true;
        }
        final created = album.created;
        return created != null &&
            (latestLocalCreated == null || created.isAfter(latestLocalCreated));
      });
      if (!firstPageEntirelyNewerOrUnknown) {
        break;
      }
    }

    final newestAlbums = _dedupeAlbums(pages);
    final newestRanks = <String, int>{};
    for (var index = 0; index < newestAlbums.length; index++) {
      final id = newestAlbums[index].id.trim();
      if (id.isNotEmpty) {
        newestRanks[id] = index;
      }
    }

    final discrepantAlbums = <Album>[];
    final artistIds = <String>{};
    for (final album in newestAlbums) {
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
      newestRanks: newestRanks,
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
    } else if (_activeExecutionPlan == null ||
        _activeExecutionPlan!.budget.allowedEndpoints.contains(
          SyncEndpoint.indexes,
        )) {
      await _refreshIndexesCursorAfterFullSync(metrics);
    }
    return state.copyWith(
      pendingHydrationCount: 0,
      remainingVerificationCount: 0,
      freshness: LibrarySyncFreshness.current,
    );
  }

  Future<bool> _catalogResumeBoundariesMatch(
    int serverId,
    int generation,
    _SyncRunMetrics metrics,
  ) async {
    final boundaries = await _database.librarySyncDao.getCatalogPageBoundaries(
      serverId: serverId,
      generation: generation,
    );
    for (final row in boundaries) {
      final checkpoint = _decodeCatalogPageCheckpoint(row.checkpointJson ?? '');
      final offset = int.tryParse(row.entityId.split(':').last);
      if (checkpoint == null || offset == null) return false;
      final page = await _withRetry(
        () => _api.getAlbumListPage(size: fastPathPageSize, offset: offset),
        metrics: metrics,
        endpoint: 'getAlbumListPage',
      );
      final signature = sha1
          .convert(utf8.encode(page.map((album) => album.id).join('\n')))
          .toString();
      if (page.length != checkpoint.rawCount ||
          signature != checkpoint.signature)
        return false;
    }
    return true;
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
    final serverId = serverConfig.id;
    if (serverId == null) {
      throw StateError('An active server ID is required for catalog sync.');
    }
    final persistentState = await _database.librarySyncDao.getOrCreateState(
      serverId,
    );
    var resumableGeneration =
        const <String>{
              'collecting',
              'awaitingDeletionConfirmation',
              'ready',
              'applying',
            }.contains(persistentState.candidateStatus) &&
            persistentState.candidateStartedAt != null &&
            DateTime.now().difference(persistentState.candidateStartedAt!) <
                const Duration(hours: 24)
        ? persistentState.candidateGeneration
        : null;
    if (resumableGeneration != null &&
        persistentState.candidateStatus != 'awaitingDeletionConfirmation' &&
        !await _catalogResumeBoundariesMatch(
          serverId,
          resumableGeneration,
          metrics,
        )) {
      resumableGeneration = null;
    }
    final catalogGeneration =
        resumableGeneration != null &&
            resumableGeneration > persistentState.currentGeneration
        ? resumableGeneration
        : persistentState.currentGeneration + 1;
    final candidateStartedAt = resumableGeneration == catalogGeneration
        ? persistentState.candidateStartedAt ?? DateTime.now()
        : DateTime.now();
    // A second deletion observation must come from a new server snapshot,
    // not from replaying the first observation's cached pages and tracks.
    if (resumableGeneration != catalogGeneration ||
        persistentState.candidateStatus == 'awaitingDeletionConfirmation') {
      await _database.librarySyncCandidateDao.clearGeneration(
        serverId: serverId,
        generation: catalogGeneration,
      );
      await _database.librarySyncDao.clearCatalogPageWork(
        serverId: serverId,
        generation: catalogGeneration,
      );
      await _database.librarySyncDao.deleteEntityWork(
        serverId: serverId,
        kind: 'catalogNewestRanks',
        entityIds: {'$catalogGeneration'},
      );
    }
    await _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        candidateGeneration: Value(catalogGeneration),
        candidateStatus: const Value('collecting'),
        candidateStartedAt: Value(candidateStartedAt),
        candidateCarriedForwardCount: const Value(0),
      ),
    );
    metrics.metadataChanged = true;
    final scanTokenAtCollection = await _recordScanObservation(
      serverId: serverId,
      metrics: metrics,
    );
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingArtists,
        candidateGeneration: catalogGeneration,
        candidateStatus: 'collecting',
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    final observedArtists = await _loadCatalogArtists(metrics);
    await _repairExternalSourceEvidence(artists: observedArtists);
    var artists = observedArtists
        .where(
          (artist) => !isExternalCatalogSource(
            id: artist.id,
            apiIsExternal: artist.isExternal,
          ),
        )
        .toList(growable: false);
    await _database.librarySyncCandidateDao.replaceArtists(
      serverId: serverId,
      generation: catalogGeneration,
      artists: _toArtistCompanions(
        artists,
        catalogGeneration: catalogGeneration,
      ),
    );
    metrics.addDbWriteBatch();

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.fetchingAlbums,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);

    late Set<String> nextAlbumIds;
    try {
      nextAlbumIds = await _discoverAlbumIdsFastPath(
        serverId: serverId,
        catalogGeneration: catalogGeneration,
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
    } on Object catch (error) {
      if (!_isIndexesUnsupported(error)) {
        rethrow;
      }
      current = _withMetrics(
        current.copyWith(
          processed: 0,
          total: artists.length,
        ),
        metrics,
      );
      onProgress?.call(current);
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
            // A detail 404 is not authoritative deletion evidence. Abandon
            // this snapshot and preserve the last committed generation.
            rethrow;
          }
        },
      );
      final albums = _dedupeAlbums([
        for (final artist in artistDetails.whereType<Artist>())
          ...artist.albums.where(
            (album) => !isExternalCatalogSource(
              id: album.id,
              apiIsExternal: album.isExternal,
            ),
          ),
      ]);
      nextAlbumIds = albums.map((album) => album.id).toSet();
      await _database.librarySyncCandidateDao.upsertAlbums(
        serverId: serverId,
        generation: catalogGeneration,
        albums: await _toAlbumCompanions(
          albums,
          pendingHydrationAlbumIds: nextAlbumIds,
          catalogGeneration: catalogGeneration,
        ),
      );
      metrics.addDbWriteBatch();
    }

    final reportedAlbumCount = artists.fold<int>(
      0,
      (sum, artist) => sum + (artist.albumCount ?? 0),
    );
    if (reportedAlbumCount > 0 && nextAlbumIds.isEmpty) {
      throw StateError(
        'Catalog candidate collected no albums even though artists reported '
        '$reportedAlbumCount albums.',
      );
    }

    await _stageCompleteNewestRanksForCandidate(
      serverId: serverId,
      generation: catalogGeneration,
      candidateAlbumIds: nextAlbumIds,
      metrics: metrics,
    );

    if (artists.isEmpty && nextAlbumIds.isNotEmpty) {
      final albums = await _database.librarySyncCandidateDao.getAlbums(
        serverId: serverId,
        generation: catalogGeneration,
      );
      final artistsById = <String, Artist>{};
      for (final album in albums) {
        final artistId = album.artistId?.trim();
        final artistName = album.artistName?.trim();
        if (artistId != null &&
            artistId.isNotEmpty &&
            artistName != null &&
            artistName.isNotEmpty) {
          artistsById.putIfAbsent(
            artistId,
            () => Artist(id: artistId, name: artistName),
          );
        }
      }
      artists = artistsById.values.toList(growable: false);
      if (artists.isNotEmpty) {
        await _database.librarySyncCandidateDao.replaceArtists(
          serverId: serverId,
          generation: catalogGeneration,
          artists: _toArtistCompanions(
            artists,
            catalogGeneration: catalogGeneration,
          ),
        );
        metrics.addDbWriteBatch();
      }
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    // The candidate tables are not watched by application providers. The
    // live catalog remains untouched until the validated generation is
    // promoted in one transaction.
    final nextArtistIds = artists.map((artist) => artist.id).toSet();

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
    current = await _hydratePendingSongs(
      state: _withMetrics(
        current.copyWith(
          metadataReady: true,
          pendingHydrationCount: await _database.librarySyncCandidateDao
              .countPendingAlbums(
                serverId: serverId,
                generation: catalogGeneration,
              ),
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
      catalogGeneration: catalogGeneration,
      candidateServerId: serverId,
      metrics: metrics,
      onProgress: onProgress,
    );
    final pendingHydrationCount =
        current.pendingHydrationCount ??
        await _database.librarySyncCandidateDao.countPendingAlbums(
          serverId: serverId,
          generation: catalogGeneration,
        );
    final carriedForwardCount =
        current.carriedForwardEntityCount +
        (pendingHydrationCount == 0
            ? 0
            : (await _database.librarySyncCandidateDao
                      .carryForwardPendingAlbums(
                        serverId: serverId,
                        generation: catalogGeneration,
                      ))
                  .length);
    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.validatingCandidate,
        candidateStatus: 'validating',
        carriedForwardEntityCount: carriedForwardCount,
      ),
      metrics,
    );
    onProgress?.call(current);

    // Candidate songs do not exist until the bulk index or per-album
    // hydration above has populated them. Comparing the live song table any
    // earlier classifies every existing song as server-missing, which blocks a
    // legitimate repair behind a bogus large-deletion confirmation.
    final staleSongIds = <String>[];
    var afterStaleId = '';
    while (true) {
      final page = await _database.librarySyncCandidateDao.getStaleSongsPage(
        serverId: serverId,
        generation: catalogGeneration,
        afterId: afterStaleId,
        limit: 500,
      );
      if (page.isEmpty) break;
      staleSongIds.addAll(page.map((row) => row.id));
      afterStaleId = page.last.id;
    }
    final deletionAllowed = await _confirmSnapshotDeletion(
      serverId: serverConfig.id,
      persistentState: persistentState,
      staleArtistIds: staleArtistIds,
      staleAlbumIds: staleAlbumIds,
      staleSongIds: staleSongIds,
      generation: catalogGeneration,
      candidateStartedAt: candidateStartedAt,
      allowPreviousConfirmation: resumableGeneration == catalogGeneration,
      artistCount: existingArtists.length,
      albumCount: existingAlbums.length,
    );
    if (!deletionAllowed) {
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          candidateGeneration: Value(catalogGeneration),
          candidateStatus: const Value('awaitingDeletionConfirmation'),
        ),
      );
      return _withMetrics(
        current.copyWith(
          stage: LibrarySyncStage.validatingCandidate,
          candidateStatus: 'awaitingDeletionConfirmation',
          freshness: LibrarySyncFreshness.repairRecommended,
          remainingVerificationCount: 1,
          clearProcessed: true,
          clearTotal: true,
        ),
        metrics,
      );
    }

    await _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        candidateStatus: const Value('ready'),
        candidateCarriedForwardCount: Value(carriedForwardCount),
      ),
    );
    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.validatingCandidate,
        candidateStatus: 'ready',
      ),
      metrics,
    );
    onProgress?.call(current);
    final promoted = await _promoteFullSyncCandidate(
      serverId: serverId,
      generation: catalogGeneration,
      scanTokenAtCollection: scanTokenAtCollection,
      explicitRepair: mode == LibrarySyncMode.forceFull,
      staleArtistIds: staleArtistIds,
      staleAlbumIds: staleAlbumIds,
      metrics: metrics,
      onStage: (stage) {
        final committed = stage == LibrarySyncStage.cleaningCandidate;
        current = _withMetrics(
          current.copyWith(
            stage: stage,
            candidateStatus: committed ? null : 'applying',
            clearCandidateStatus: committed,
            clearCandidateGeneration: committed,
          ),
          metrics,
        );
        onProgress?.call(current);
      },
    );
    if (!promoted) {
      current = _withMetrics(
        current.copyWith(
          stage: LibrarySyncStage.collectingCandidate,
          candidateStatus: 'collecting',
          freshness: LibrarySyncFreshness.repairRecommended,
        ),
        metrics,
      );
      onProgress?.call(current);
      return current;
    }

    current = current.copyWith(catalogPublishedThisRun: true);

    if (syncAuxiliary) {
      current = await _syncPlaylistHeadersBestEffort(
        current: current,
        metrics: metrics,
        onProgress: onProgress,
      );
    }

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
        clearCandidateGeneration: true,
        clearCandidateStatus: true,
        carriedForwardEntityCount: carriedForwardCount,
        clearProcessed: true,
        clearTotal: true,
      ),
      metrics,
    );
    onProgress?.call(current);
    return current;
  }

  /// Observes the server scan state and reports whether a completed scan has
  /// not been reconciled yet.
  ///
  /// Servers without `getScanStatus` are recorded once as unsupported and
  /// never re-probed into repeated failures; in-progress scans produce no
  /// token, so collection that overlaps a scan cannot claim completeness.
  Future<bool> _observeScanStatusAndDetectChange({
    required int serverId,
    required _SyncRunMetrics metrics,
  }) async {
    String? token;
    var supported = true;
    var scanning = false;
    try {
      final status = await _api.getScanStatusOrNull();
      metrics.recordApiAttempt(
        elapsed: Duration.zero,
        isRetryAttempt: false,
        endpoint: 'getScanStatus',
      );
      if (status == null) {
        supported = false;
      } else if (status.scanning) {
        scanning = true;
      } else {
        token = status.lastScan?.toIso8601String();
      }
    } on SubsonicException catch (error) {
      AppLogger.warning('Scan status unavailable: $error');
      return false;
    }
    await _database.librarySyncDao.recordScanObservation(
      serverId: serverId,
      scanInProgress: scanning,
      supported: supported,
      providerScanToken: token,
    );
    if (token == null) {
      return false;
    }
    final observation = await _database.librarySyncDao.getScanObservation(
      serverId,
    );
    return observation != null &&
        observation.pendingReconciliation &&
        observation.observedToken == token &&
        observation.reconciledToken != token;
  }

  /// Observes the server scan state once and records it.
  ///
  /// Returns the completed-scan token (null while a scan is running or when
  /// the provider exposes no token field) and whether `getScanStatus` is
  /// supported at all.
  Future<(String?, bool)> _recordScanObservation({
    required int serverId,
    required _SyncRunMetrics metrics,
  }) async {
    try {
      final status = await _api.getScanStatusOrNull();
      metrics.recordApiAttempt(
        elapsed: Duration.zero,
        isRetryAttempt: false,
        endpoint: 'getScanStatus',
      );
      if (status == null) {
        await _database.librarySyncDao.recordScanObservation(
          serverId: serverId,
          scanInProgress: false,
          supported: false,
        );
        return (null, false);
      }
      if (status.scanning) {
        await _database.librarySyncDao.recordScanObservation(
          serverId: serverId,
          scanInProgress: true,
          supported: true,
        );
        return (null, true);
      }
      final token = status.lastScan?.toIso8601String();
      await _database.librarySyncDao.recordScanObservation(
        serverId: serverId,
        scanInProgress: false,
        supported: true,
        providerScanToken: token,
      );
      return (token, true);
    } on SubsonicException catch (error) {
      AppLogger.warning('Scan status unavailable: $error');
      return (null, false);
    }
  }

  /// True when a scan landed between the two observations and the candidate's
  /// completeness evidence can no longer be trusted.
  bool _scanInvalidatedCollection(
    (String?, bool) atCollection,
    (String?, bool) atPromotion,
  ) {
    final (collectionToken, collectionSupported) = atCollection;
    final (promotionToken, promotionSupported) = atPromotion;
    if (!collectionSupported || !promotionSupported) {
      // Unsupported scan status must not block synchronization; providers
      // without tokens stay on their existing discovery/audit mechanisms.
      return false;
    }
    // A scan running at collection start, or a changed completed token at
    // promotion time, both mean the candidate may miss post-scan content.
    return collectionToken != promotionToken;
  }

  /// Returns true when the candidate was promoted; false when a scan landed
  /// during collection and the candidate's completeness evidence was withheld
  /// for a safe recollect.
  Future<bool> _promoteFullSyncCandidate({
    required int serverId,
    required int generation,
    required (String?, bool) scanTokenAtCollection,
    required bool explicitRepair,
    required List<String> staleArtistIds,
    required List<String> staleAlbumIds,
    required _SyncRunMetrics metrics,
    required void Function(LibrarySyncStage) onStage,
  }) async {
    final syncState = await _database.librarySyncDao.getOrCreateState(serverId);
    final candidateStartedAt =
        syncState.candidateStartedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final scanAtPromotion = await _recordScanObservation(
      serverId: serverId,
      metrics: metrics,
    );
    if (_scanInvalidatedCollection(scanTokenAtCollection, scanAtPromotion)) {
      // The server scanned while this candidate was collected. Promoting it
      // would commit incomplete evidence; keep the committed catalog visible
      // and let the resumable planner recollect missing work.
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          candidateStatus: const Value('collecting'),
        ),
      );
      await _database.librarySyncDao.recordOperationLedgerEntry(
        serverId: serverId,
        operation: 'catalogPromotion',
        reason: 'scanChangedDuringCollection',
        details: <String, Object?>{
          'generation': generation,
          'tokenAtCollection': scanTokenAtCollection.$1,
          'tokenAtPromotion': scanAtPromotion.$1,
        },
      );
      AppLogger.warning(
        'Deferred catalog promotion: server scan changed during collection.',
      );
      return false;
    }
    final provisionalSongs = await _database.songIdentityDao
        .getProvisionalSongs();
    final identitySession = provisionalSongs.isEmpty
        ? null
        : await SongIdentityReconciler(
            _database.songIdentityDao,
            onBeforeRemap: onBeforeSongIdentityRemap,
            readActiveSongId: readActiveSongId,
          ).startSession(provisionalSongs: provisionalSongs);
    final analysis = await LibraryCatalogDiffAnalyzer(
      _database,
      readActivePlayback: () =>
          (readProtectedSongIds?.call() ?? const <String>{}).isNotEmpty,
    ).analyze(serverId: serverId, generation: generation);
    AppLogger.info(
      'Catalog candidate classified in '
      '${analysis.duration.inMilliseconds}ms: '
      'changed=${analysis.changedCount} '
      'unchanged=${analysis.unchangedCount} '
      'pages=${analysis.pageCount} '
      'maxPage=${analysis.maximumPageSize} '
      'rssGrowth=${analysis.rssGrowthBytes}.',
    );
    final stopwatch = Stopwatch()..start();
    final deferredCacheFiles = <String>[];
    var removedSongCount = 0;
    var retainedUnavailableCount = 0;
    await _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        candidateStatus: const Value('applying'),
      ),
    );
    onStage(LibrarySyncStage.applyingCandidate);
    await _database.transaction(() async {
      final beforeCatalog = await _database.libraryDao.getCatalogCounts();
      final candidateNewestRanks = await _database.librarySyncCandidateDao
          .getRecentlyAddedRanks(serverId: serverId, generation: generation);
      await _database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
        candidateNewestRanks,
      );
      // Read the mutation journals inside the apply transaction so a local
      // write cannot land between the protection snapshot and the upserts.
      final localStarMutations = await _database.librarySyncDao
          .getLocalStarMutationsSince(candidateStartedAt);
      final localRatingMutations = await _database.librarySyncDao
          .getLocalMutationsSince(candidateStartedAt, operation: 'rating');
      final pendingActions = await _database.starSyncDao.getPendingActions();
      final pendingStars = <String, Set<String>>{
        'artist': <String>{},
        'album': <String>{},
        'song': <String>{},
      };
      for (final action in pendingActions) {
        if (action.operation == 'rating') {
          localRatingMutations[action.itemType]?.add(action.itemId);
        } else {
          pendingStars[action.itemType]?.add(action.itemId);
        }
      }
      for (final entry in localStarMutations.entries) {
        pendingStars[entry.key]?.addAll(entry.value);
      }
      final changedArtistIds = <String>[];
      final changedAlbumIds = <String>[];
      final changedSongIds = <String>[];
      var afterArtistId = '';
      while (true) {
        final page = await _database.librarySyncCandidateDao
            .getChangedArtistsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterArtistId,
              limit: writeChunkSize,
            );
        if (page.isEmpty) break;
        changedArtistIds.addAll(page.map((artist) => artist.id));
        await _database.libraryDao.upsertArtists([
          for (final artist in page)
            ArtistsTableCompanion.insert(
              id: artist.id,
              name: artist.name,
              albumCount: Value(artist.albumCount),
              coverArt: Value(artist.coverArt),
              starred: pendingStars['artist']!.contains(artist.id)
                  ? const Value.absent()
                  : Value(artist.starred),
              artistMbid: Value(artist.artistMbid),
              catalogGeneration: Value(generation),
            ),
        ]);
        afterArtistId = page.last.id;
      }

      var afterAlbumId = '';
      while (true) {
        final page = await _database.librarySyncCandidateDao
            .getChangedAlbumsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterAlbumId,
              limit: writeChunkSize,
            );
        if (page.isEmpty) break;
        changedAlbumIds.addAll(page.map((album) => album.id));
        await _database.libraryDao.upsertAlbums(
          [
            for (final album in page)
              AlbumsTableCompanion.insert(
                id: album.id,
                name: album.name,
                artistId: Value(album.artistId),
                artistName: Value(album.artistName),
                artists: Value(album.artists),
                songCount: Value(album.songCount),
                duration: Value(album.duration),
                year: Value(album.year),
                genre: Value(album.genre),
                coverArt: Value(album.coverArt),
                songsHydrated: Value(album.songsHydrated),
                starred: pendingStars['album']!.contains(album.id)
                    ? const Value.absent()
                    : Value(album.starred),
                userRating: localRatingMutations['album']!.contains(album.id)
                    ? const Value.absent()
                    : Value(album.userRating),
                playCount: Value(album.playCount),
                serverCreatedAt: Value(album.serverCreatedAt),
                recentlyAddedRank: Value(album.recentlyAddedRank),
                releaseMbid: Value(album.releaseMbid),
                catalogGeneration: Value(generation),
              ),
          ],
          preserveHydrationState: false,
        );
        afterAlbumId = page.last.id;
      }

      var afterSongId = '';
      while (true) {
        final page = await _database.librarySyncCandidateDao
            .getChangedSongsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterSongId,
              limit: writeChunkSize,
            );
        if (page.isEmpty) break;
        changedSongIds.addAll(page.map((song) => song.id));
        await _database.libraryDao.upsertSongs([
          for (final song in page)
            SongsTableCompanion.insert(
              id: song.id,
              title: song.title,
              albumId: Value(song.albumId),
              artistId: Value(song.artistId),
              artistName: Value(song.artistName),
              albumName: Value(song.albumName),
              track: Value(song.track),
              discNumber: Value(song.discNumber),
              duration: Value(song.duration),
              bitRate: Value(song.bitRate),
              sampleRate: Value(song.sampleRate),
              contentType: Value(song.contentType),
              suffix: Value(song.suffix),
              size: Value(song.size),
              coverArt: Value(song.coverArt),
              starred: pendingStars['song']!.contains(song.id)
                  ? const Value.absent()
                  : Value(song.starred),
              recordingMbid: Value(song.recordingMbid),
              userRating: localRatingMutations['song']!.contains(song.id)
                  ? const Value.absent()
                  : Value(song.userRating),
              playCount: Value(song.playCount),
              createdAt: Value(song.createdAt),
              catalogGeneration: Value(generation),
              replayGainTrackGain: Value(song.replayGainTrackGain),
              replayGainAlbumGain: Value(song.replayGainAlbumGain),
              replayGainTrackPeak: Value(song.replayGainTrackPeak),
              replayGainAlbumPeak: Value(song.replayGainAlbumPeak),
            ),
        ]);
        afterSongId = page.last.id;
      }

      // Explicit repairs may carry new cover bytes behind unchanged cover-art
      // IDs. A targeted revision bump refetches exactly the changed entries.
      if (explicitRepair) {
        await _database.libraryDao.bumpCoverArtRevisions(
          songIds: changedSongIds,
          albumIds: changedAlbumIds,
          artistIds: changedArtistIds,
        );
      }

      // Verified candidate tracks include bulk snapshots, but never locally
      // carried-forward content. Refresh the evidence even for no-op diffs.
      await _database.customUpdate(
        'UPDATE albums SET songs_verified_at = ? WHERE id IN ('
        'SELECT id FROM library_sync_candidate_albums '
        'WHERE server_id = ? AND generation = ? '
        'AND songs_hydrated = 1 AND carried_forward = 0)',
        variables: [
          Variable.withDateTime(candidateStartedAt),
          Variable.withInt(serverId),
          Variable.withInt(generation),
        ],
        updates: {_database.albumsTable},
      );

      if (identitySession != null) {
        var afterCanonicalId = '';
        while (true) {
          final page = await _database.librarySyncCandidateDao.getSongsPage(
            serverId: serverId,
            generation: generation,
            afterId: afterCanonicalId,
            limit: writeChunkSize,
          );
          if (page.isEmpty) break;
          final canonicalSongs = await _database.libraryDao.getSongsByIds(
            page.map((song) => song.id),
          );
          await identitySession.reconcile(canonicalSongs);
          afterCanonicalId = page.last.id;
        }
        // Claims apply only after the complete replacement set has been
        // observed, so candidates contended for by several canonical rows
        // resolve as review cases instead of honoring page order.
        await identitySession.finalize();
        final identitySummary = identitySession.summary;
        metrics.canonicalizedSongCount +=
            identitySummary.canonicalizedSongCount;
        metrics.ambiguousMatchCount += identitySummary.ambiguousMatchCount;
        for (final ambiguous in identitySummary.ambiguousCases) {
          final canonicalId = ambiguous.canonicalSongId;
          if (canonicalId == null) {
            continue;
          }
          await _database.librarySyncDao.recordRecoveryReview(
            serverId: serverId,
            entityType: 'song',
            oldId: canonicalId,
            reason: 'ambiguousMatch',
            evidenceGeneration: generation,
            candidateJson: jsonEncode(<String, Object?>{
              'candidateIds': ambiguous.candidateIds,
              'matchReason': ambiguous.reason.name,
            }),
          );
        }
        if (identitySummary.aliases.isNotEmpty ||
            identitySummary.ambiguousMatchCount > 0 ||
            identitySummary.retainedProvisionalCount > 0) {
          AppLogger.info(
            'Song identity reconciliation: '
            'canonicalized=${identitySummary.canonicalizedSongCount} '
            'ambiguous=${identitySummary.ambiguousMatchCount} '
            'retainedProvisional='
            '${identitySummary.retainedProvisionalCount}.',
          );
        }
      }

      final preserved = await _database.libraryDao
          .preserveCachedLegacyRowsAsProvisional(
            staleArtistIds: staleArtistIds,
            staleAlbumIds: staleAlbumIds,
            protectedSongIds: readProtectedSongIds?.call() ?? const <String>{},
          );

      var afterStaleSongId = '';
      while (true) {
        final staleSongs = await _database.librarySyncCandidateDao
            .getStaleSongsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterStaleSongId,
              limit: writeChunkSize,
            );
        if (staleSongs.isEmpty) break;
        afterStaleSongId = staleSongs.last.id;
        final removal = await _database.libraryDao.retainOrRemoveServerSongs(
          staleSongs,
        );
        removedSongCount +=
            staleSongs.length - removal.retainedUnavailableIds.length;
        deferredCacheFiles.addAll(removal.deferredCacheFiles);
        retainedUnavailableCount += removal.retainedUnavailableIds.length;
        final retainedById = <String, SongsTableData>{
          for (final song in staleSongs) song.id: song,
        };
        final retainedSongs = <SongsTableData>[
          for (final retainedId in removal.retainedUnavailableIds)
            if (retainedById[retainedId] case final retainedSong?) retainedSong,
        ];
        await _database.librarySyncDao.recordRecoveryReviewBatch(
          serverId: serverId,
          retainedSongs: retainedSongs,
          evidenceGeneration: generation,
        );
      }

      // Album/artist relinking runs after rows are preserved as provisional
      // and the retained song set is final, but before removable stale rows
      // are deleted: unresolved entities must still be reviewable from their
      // recorded metadata, and remapped entities delete their own rows.
      final entityIdentitySummary = await EntityIdentityReconciler(_database)
          .reconcile(
            serverId: serverId,
            generation: generation,
            songAliases:
                identitySession?.summary.aliases ?? const <SongIdentityAlias>[],
            provisionalSongs: provisionalSongs,
          );
      if (entityIdentitySummary.aliases > 0 ||
          entityIdentitySummary.reviewCount > 0) {
        AppLogger.info(
          'Album/artist identity reconciliation: '
          'albumAliases=${entityIdentitySummary.albumAliases} '
          'artistAliases=${entityIdentitySummary.artistAliases} '
          'review=${entityIdentitySummary.reviewCount}.',
        );
      }

      final removableAlbumIds = staleAlbumIds
          .where((id) => !preserved.albumIds.contains(id))
          .toList(growable: false);
      final removableArtistIds = staleArtistIds
          .where((id) => !preserved.artistIds.contains(id))
          .toList(growable: false);
      if (removableAlbumIds.isNotEmpty) {
        await _database.libraryDao.deleteAlbumsByIds(removableAlbumIds);
      }
      await _database.libraryDao.deleteArtistsByIds(removableArtistIds);

      final afterCatalog = await _database.libraryDao.getCatalogCounts();
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverId),
          currentGeneration: Value(generation),
          candidateGeneration: const Value(null),
          candidateStatus: const Value(null),
          candidateStartedAt: const Value(null),
          deletionCandidateFingerprint: const Value(null),
          deletionCandidateCount: const Value(0),
          lastApplyDurationMs: Value(stopwatch.elapsedMilliseconds),
          lastPromotionDiagnosticsJson: Value(
            jsonEncode(<String, Object>{
              'analysisDurationMs': analysis.duration.inMilliseconds,
              'applyDurationMs': stopwatch.elapsedMilliseconds,
              'changed': analysis.changedCount,
              'unchanged': analysis.unchangedCount,
              'artistChanged': analysis.artistChangedCount,
              'albumChanged': analysis.albumChangedCount,
              'songChanged': analysis.songChangedCount,
              'removedSongs': removedSongCount,
              'pages': analysis.pageCount,
              'maximumPageSize': analysis.maximumPageSize,
              'maximumPageLatencyMs':
                  analysis.maximumPageLatency.inMilliseconds,
              'rssGrowthBytes': analysis.rssGrowthBytes,
              'aliases': identitySession?.summary.aliases.length ?? 0,
              'albumAliases': entityIdentitySummary.albumAliases,
              'artistAliases': entityIdentitySummary.artistAliases,
            }),
          ),
        ),
      );
      // Promotion is the durable completion boundary for broad catalog work.
      // Auxiliary and unavailable-target hydration continue as independent
      // tasks, so a process exit after this transaction must not re-run the
      // entire snapshot on the next launch.
      await _database.librarySyncDao.completeRunningCatalogWork(serverId);
      await _database.librarySyncDao.recordOperationLedgerEntry(
        serverId: serverId,
        operation: 'catalogPromotion',
        reason: 'validatedFullCandidate',
        details: <String, Object?>{
          'generation': generation,
          'before': <String, int>{
            'artists': beforeCatalog.artists,
            'albums': beforeCatalog.albums,
            'songs': beforeCatalog.songs,
          },
          'after': <String, int>{
            'artists': afterCatalog.artists,
            'albums': afterCatalog.albums,
            'songs': afterCatalog.songs,
          },
          'changed': analysis.changedCount,
          'unchanged': analysis.unchangedCount,
          'removed': <String, int>{
            'artists': removableArtistIds.length,
            'albums': removableAlbumIds.length,
            'songs': removedSongCount,
          },
          'retained': <String, int>{
            'artists': preserved.artistIds.length,
            'albums': preserved.albumIds.length,
            'songs': preserved.songIds.length,
          },
          'retainedUnavailable': retainedUnavailableCount,
          'aliases': identitySession?.summary.aliases.length ?? 0,
          'albumAliases': entityIdentitySummary.albumAliases,
          'artistAliases': entityIdentitySummary.artistAliases,
          'reviewEntries': entityIdentitySummary.reviewCount,
        },
      );
    });
    stopwatch.stop();
    AppLogger.info(
      'Catalog candidate promoted in ${stopwatch.elapsedMilliseconds}ms: '
      'writes=${analysis.changedCount}.',
    );
    metrics.addDbWriteBatch();
    onStage(LibrarySyncStage.cleaningCandidate);
    await _database.libraryDao.cleanupRemovedCacheFiles(deferredCacheFiles);
    await _database.librarySyncCandidateDao.clearGeneration(
      serverId: serverId,
      generation: generation,
    );
    if (scanAtPromotion.$1 != null) {
      // The promoted snapshot covered this scan's server state.
      await _database.librarySyncDao.markScanReconciled(
        serverId: serverId,
        token: scanAtPromotion.$1!,
      );
    }
    return true;
  }

  Future<bool> _confirmSnapshotDeletion({
    required int? serverId,
    required LibrarySyncStateTableData? persistentState,
    required List<String> staleArtistIds,
    required List<String> staleAlbumIds,
    required List<String> staleSongIds,
    required int generation,
    required DateTime candidateStartedAt,
    required bool allowPreviousConfirmation,
    required int artistCount,
    required int albumCount,
  }) async {
    final staleSongCount = staleSongIds.length;
    if (staleArtistIds.isEmpty &&
        staleAlbumIds.isEmpty &&
        staleSongCount == 0) {
      return true;
    }
    final removesManyArtists = staleArtistIds.length * 10 > artistCount;
    final removesManyAlbums = staleAlbumIds.length * 10 > albumCount;
    final requiresConfirmation =
        removesManyArtists || removesManyAlbums || staleSongCount > 500;
    if (!requiresConfirmation || serverId == null || persistentState == null) {
      return true;
    }
    final artistIds = [...staleArtistIds]..sort();
    final albumIds = [...staleAlbumIds]..sort();
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              generation,
              candidateStartedAt.millisecondsSinceEpoch ~/ 1000,
              artistIds,
              albumIds,
              [...staleSongIds]..sort(),
            ]),
          ),
        )
        .toString();
    final candidateCount =
        staleArtistIds.length + staleAlbumIds.length + staleSongCount;
    if (allowPreviousConfirmation &&
        persistentState.deletionCandidateFingerprint == fingerprint &&
        persistentState.deletionCandidateCount == candidateCount) {
      return true;
    }
    await _database.librarySyncDao.writeState(
      LibrarySyncStateTableCompanion(
        serverId: Value(serverId),
        deletionCandidateFingerprint: Value(fingerprint),
        deletionCandidateCount: Value(candidateCount),
      ),
    );
    return false;
  }

  Future<LibrarySyncState> _runIncrementalSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required bool manual,
    required Iterable<String> priorityAlbumIds,
    required bool syncAuxiliary,
    required bool compatibilityAudit,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final limitedMeteredManualDiscovery = _allowsLimitedMeteredManualDiscovery(
      manual: manual,
    );
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
    } else if (_activeExecutionPlan != null &&
        !_activeExecutionPlan!.budget.allowedEndpoints.contains(
          SyncEndpoint.artists,
        )) {
      // Bounded discovery cannot silently expand into a full artist listing.
      // Known artists plus the newest feed provide its scoped work; the
      // separately scheduled compatibility audit owns broad enumeration.
      for (final artist in await _database.libraryDao.getAllArtists()) {
        snapshotArtists[artist.id] = Artist(
          id: artist.id,
          name: artist.name,
          albumCount: artist.albumCount,
        );
      }
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
    final targetCursor = indexesReliable ? indexes?.lastModified : null;
    final cursorChanged =
        targetCursor != null &&
        (committedCursor == null ||
            targetCursor.toUtc() != committedCursor.toUtc());
    final healthProbeDue =
        fallbackVerification ||
        // `getIndexes` only tells us that the artist collection changed. It
        // does not identify which artist changed, so it cannot rule out a new
        // album under an existing artist. A user-requested check always runs
        // the bounded newest-album discovery, independent of that cursor.
        manual ||
        (_activeExecutionPlan?.budget.maxNewestPages ?? 0) > 0 ||
        lastHealthCheck == null ||
        now.difference(lastHealthCheck) >= _defaultHealthProbeStaleAfter;
    var healthProbe = const _NewestAlbumHealthProbe(
      artistIds: <String>{},
      discrepantAlbums: <Album>[],
      newestRanks: <String, int>{},
    );
    if (healthProbeDue) {
      if (limitedMeteredManualDiscovery) {
        current = _withMetrics(
          current.copyWith(
            stage: LibrarySyncStage.fetchingAlbums,
            clearProcessed: true,
            clearTotal: true,
          ),
          metrics,
        );
        onProgress?.call(current);
      }
      healthProbe = await _runNewestAlbumHealthProbe(metrics, manual: manual);
      await _updateVerificationCapabilities(
        <String, Object?>{_libraryHealthCheckedAtCapabilityKey: now},
        metrics,
      );
      await _stageNewestAlbumsForHydration(
        healthProbe.discrepantAlbums,
        metrics,
        newestRanks: healthProbe.newestRanks,
        snapshotStartedAt: state.startedAt,
      );
    }

    // Cellular "Check for updates" deliberately stops here: the newest feed
    // identifies candidate albums without enumerating artists or indexing the
    // library's songs. Hydrate at most a few changed albums (each response is
    // budgeted by the existing metered transport guard); leave all other
    // pending work for Wi-Fi or the explicit broad-data action.
    if (limitedMeteredManualDiscovery) {
      final discoveredAlbumIds = healthProbe.discrepantAlbums
          .map((album) => album.id)
          .take(_meteredManualAlbumHydrationLimit)
          .toList(growable: false);
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
        priorityAlbumIds: discoveredAlbumIds,
        restrictedAlbumIds: discoveredAlbumIds,
        serverCapabilitiesJson: serverConfig.capabilitiesJson,
        storedBulkSongSearchQuery: null,
        excludedAlbumIds: const <String>{},
        metrics: metrics,
        onProgress: onProgress,
      );
      final pendingHydrationCount = await _database.libraryDao
          .countPendingHydrationAlbums();
      if (pendingHydrationCount > 0) {
        metrics.skippedReason = 'meteredManualDiscoveryBounded';
      }
      return _withMetrics(
        current.copyWith(
          stage: LibrarySyncStage.finalizing,
          remainingVerificationCount: 0,
          freshness: pendingHydrationCount > 0
              ? LibrarySyncFreshness.verificationPending
              : current.freshness,
          clearProcessed: true,
          clearTotal: true,
        ),
        metrics,
      );
    }

    final indexesFingerprint = indexesReliable && indexes != null
        ? _fingerprintIndexes(indexes)
        : _fingerprintArtistIds(snapshotArtists.keys);
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

    final urgentArtistIds = await _prioritizeVerificationArtists(
      snapshotArtists: snapshotArtists,
      healthProbeArtistIds: const <String>{},
      includeRemaining: false,
    );
    final fullAuditArtistIds = await _prioritizeVerificationArtists(
      snapshotArtists: snapshotArtists,
      healthProbeArtistIds: const <String>{},
    );
    final storedRemainingArtistIds = storedPendingArtistIds.sublist(
      storedPendingOffset,
    );
    var pendingOffset = 0;
    int? nextAuditOffset;
    late List<String> orderedArtistIds;
    if (compatibilityAudit &&
        !cursorChanged &&
        !samePendingSnapshot &&
        storedRemainingArtistIds.isEmpty) {
      final serverId = serverConfig.id;
      final auditState = serverId == null
          ? null
          : await _database.librarySyncDao.getOrCreateState(serverId);
      final candidates = fullAuditArtistIds;
      if (candidates.isEmpty) {
        orderedArtistIds = <String>[];
        nextAuditOffset = 0;
      } else {
        final start = (auditState?.auditOffset ?? 0) % candidates.length;
        orderedArtistIds = candidates
            .skip(start)
            .take(_compatibilityArtistVerificationLimit)
            .toList(growable: false);
        final end = start + orderedArtistIds.length;
        nextAuditOffset = end >= candidates.length ? 0 : end;
      }
    } else if (samePendingSnapshot) {
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

    var passLimit = fallbackVerification
        ? _compatibilityArtistVerificationLimit
        : networkType == NetworkType.cellular
        ? _cellularManualArtistVerificationLimit
        : _normalArtistVerificationLimit;
    if (_activeExecutionPlan != null) {
      final boundedLimit =
          _activeExecutionPlan!.request.intent ==
              SyncRunIntent.automaticCatalogCheck
          ? 24
          : 48;
      if (passLimit > boundedLimit) passLimit = boundedLimit;
    }
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

    final failedArtistIds = <String>{};
    Object? interruptedPass;
    final details = await _mapConcurrent<String, Artist?>(
      passArtistIds,
      _artistConcurrency,
      (artistId) async {
        if (interruptedPass != null) {
          failedArtistIds.add(artistId);
          return null;
        }
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
          // A detail 404 is not deletion authority. Keep the locally known
          // artist pending until a complete catalog candidate can verify it.
          failedArtistIds.add(artistId);
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
          if (SyncRequestScope.current?.stopped != null ||
              error is SyncNetworkDeferredException ||
              error is SyncCancelledException) {
            interruptedPass = SyncRequestScope.current?.stopped ?? error;
          } else if (_isFatalEntityError(error)) {
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

    await _repairExternalSourceEvidence(
      artists: details.whereType<Artist>(),
      albums: details.whereType<Artist>().expand((artist) => artist.albums),
    );
    final artistDetails = details
        .whereType<Artist>()
        .where(
          (artist) => !isExternalCatalogSource(
            id: artist.id,
            apiIsExternal: artist.isExternal,
          ),
        )
        .toList(growable: false);
    final touchedArtistIds = artistDetails.map((artist) => artist.id).toSet();
    final changedArtistDetails = <Artist>[];
    for (final artist in artistDetails) {
      final existing = await _database.libraryDao.getArtistById(artist.id);
      if (existing == null || _artistMetadataChanged(existing, artist)) {
        changedArtistDetails.add(artist);
      }
    }
    if (changedArtistDetails.isNotEmpty) {
      metrics.metadataChanged = true;
    }

    current = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.persistingMetadata),
      metrics,
    );
    onProgress?.call(current);

    final albumsByArtist = <String, List<Album>>{
      for (final artist in artistDetails)
        artist.id: artist.albums
            .where(
              (album) => !isExternalCatalogSource(
                id: album.id,
                apiIsExternal: album.isExternal,
              ),
            )
            .toList(growable: false),
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

    final changedAlbumRows = changedOrNewAlbums.isEmpty
        ? const <AlbumsTableCompanion>[]
        : await _toAlbumCompanions(
            changedOrNewAlbums,
            pendingHydrationAlbumIds: albumsNeedingHydration,
          );
    final hydratedWithoutSongRefresh = changedOrNewAlbums
        .map((album) => album.id)
        .where((id) => !albumsNeedingHydration.contains(id))
        .toList(growable: false);
    await _database.transaction(() async {
      if (changedArtistDetails.isNotEmpty) {
        await _database.libraryDao.upsertArtists(
          _toArtistCompanions(changedArtistDetails),
          snapshotStartedAt: state.startedAt,
        );
        metrics.addDbWriteBatch();
      }
      if (changedAlbumRows.isNotEmpty) {
        metrics.metadataChanged = true;
        await _database.libraryDao.upsertAlbums(
          changedAlbumRows,
          snapshotStartedAt: state.startedAt,
        );
        metrics.addDbWriteBatch();
      }
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
      // Commit the traversal cursor with its metadata before any subsequent
      // track request can exhaust this run's budget. Successful details from
      // an interrupted batch advance too; failed/unstarted IDs remain queued.
      if (orderedArtistIds.isNotEmpty) {
        await _updateVerificationCapabilities({
          _libraryPendingFingerprintCapabilityKey: indexesFingerprint,
          _libraryPendingCursorCapabilityKey: targetCursor,
          _libraryPendingOffsetCapabilityKey: nextPendingOffset,
          _libraryPendingArtistIdsCapabilityKey: jsonEncode(orderedArtistIds),
          _libraryFreshnessCapabilityKey:
              LibrarySyncFreshness.verificationPending.name,
        }, metrics);
      }
      // Artist-detail and bounded index responses are discovery evidence, not
      // a deletion authority. A compatible server can return a partial artist
      // payload during maintenance or capability fallback; deleting its local
      // albums here made ordinary incremental work remove offline library rows
      // after one response. Full candidate promotion is the only catalog
      // deletion path because it validates a complete snapshot and applies the
      // explicit large-deletion confirmation contract.
      //
      // A detail 404 likewise remains a failed verification item (see above)
      // rather than removing its local tree.
    });

    if (interruptedPass != null) throw interruptedPass!;

    // An unchanged artist index/header cannot prove track metadata freshness.
    // Reserve a bounded oldest-first slice on each eligible catalog pass.
    if (_currentSyncPolicy.allowsBackgroundSync) {
      final dueAlbumIds = await _database.libraryDao
          .getAlbumsDueForSongVerification(
            before: now.subtract(const Duration(days: 7)),
            limit: 16,
          );
      if (dueAlbumIds.isNotEmpty) {
        await _database.libraryDao.markAlbumsPendingHydrationByIds(dueAlbumIds);
        metrics.addDbWriteBatch();
      }
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
      priorityAlbumIds: <String>{
        ...priorityAlbumIds,
        ...healthProbe.discrepantAlbums.map((album) => album.id),
      },
      serverCapabilitiesJson: serverConfig.capabilitiesJson,
      storedBulkSongSearchQuery: _readStoredBulkSongSearchQuery(
        serverConfig.capabilitiesJson,
      ),
      excludedAlbumIds: hydratedWithoutSongRefresh,
      metrics: metrics,
      onProgress: onProgress,
    );

    if (syncAuxiliary ||
        (_activeExecutionPlan == null &&
            metrics.metadataChanged &&
            !metrics.verificationContinuation)) {
      current = await _syncPlaylistHeadersBestEffort(
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
    if (nextAuditOffset != null &&
        remainingVerificationCount == 0 &&
        serverConfig.id != null) {
      await _database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: Value(serverConfig.id!),
          auditOffset: Value(nextAuditOffset),
          lastAuditAt: Value(now),
        ),
      );
      metrics.addDbWriteBatch();
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

  /// Makes the bounded `newest` feed useful as a direct change path.
  ///
  /// `getIndexes` is intentionally only an artist-collection invalidation
  /// signal. Its contents cannot tell us which existing artist received a new
  /// album. The newest feed does, and every listed album is subsequently
  /// hydrated through the normal song and identity-reconciliation path.
  Future<void> _repairExternalSourceEvidence({
    Iterable<Artist> artists = const [],
    Iterable<Album> albums = const [],
    Iterable<Song> songs = const [],
  }) async {
    final artistIds = artists
        .where((row) => row.isExternal == true)
        .map((row) => row.id)
        .toList();
    final albumIds = albums
        .where((row) => row.isExternal == true)
        .map((row) => row.id)
        .toList();
    final songIds = songs
        .where((row) => row.isExternal == true)
        .map((row) => row.id)
        .toList();
    if (artistIds.isEmpty && albumIds.isEmpty && songIds.isEmpty) return;
    await _database.libraryDao.repairExternalSourceEvidence(
      artistIds: artistIds,
      albumIds: albumIds,
      songIds: songIds,
      serverId: (await _serverConfigRepository.getActiveServer())?.id,
    );
  }

  Future<void> _stageNewestAlbumsForHydration(
    Iterable<Album> albums,
    _SyncRunMetrics metrics, {
    required Map<String, int> newestRanks,
    DateTime? snapshotStartedAt,
  }) async {
    final candidates = albums
        .where(
          (album) =>
              album.id.trim().isNotEmpty &&
              !isExternalCatalogSource(
                id: album.id,
                apiIsExternal: album.isExternal,
              ),
        )
        .toList(growable: false);
    if (candidates.isEmpty) {
      await _database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
        newestRanks,
        complete: false,
      );
      return;
    }
    final knownArtistIds = await _database.libraryDao.getArtistIds();
    final missingArtists = <ArtistsTableCompanion>[];
    for (final album in candidates) {
      final artistId = album.artistId?.trim();
      if (artistId == null ||
          artistId.isEmpty ||
          !knownArtistIds.add(artistId)) {
        continue;
      }
      missingArtists.add(
        ArtistsTableCompanion.insert(
          id: artistId,
          name: album.artist?.trim().isNotEmpty == true
              ? album.artist!.trim()
              : 'Unknown Artist',
        ),
      );
    }
    final existing = {
      for (final row in await _database.libraryDao.getAlbumsByIds(
        candidates.map((album) => album.id),
      ))
        row.id: row,
    };
    final needsTracks = candidates
        .where((album) {
          final current = existing[album.id];
          return current == null || _albumRequiresSongHydration(current, album);
        })
        .map((album) => album.id)
        .toSet();
    final albumRows = await _toAlbumCompanions(
      candidates,
      pendingHydrationAlbumIds: needsTracks,
      newestRanks: newestRanks,
    );
    await _database.transaction(() async {
      if (missingArtists.isNotEmpty) {
        await _database.libraryDao.upsertArtists(
          missingArtists,
          snapshotStartedAt: snapshotStartedAt,
        );
      }
      await _database.libraryDao.upsertAlbums(
        albumRows,
        snapshotStartedAt: snapshotStartedAt,
      );
      await _database.libraryDao.markAlbumsPendingHydrationByIds(
        needsTracks,
      );
      await _database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
        newestRanks,
        complete: false,
      );
    });
    metrics
      ..metadataChanged = true
      ..addDbWriteBatch();
  }

  Future<LibrarySyncState> _syncPlaylistHeadersBestEffort({
    required LibrarySyncState current,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    var state = _withMetrics(
      current.copyWith(stage: LibrarySyncStage.fetchingPlaylists),
      metrics,
    );
    onProgress?.call(state);
    try {
      await _syncPlaylistHeadersStrict(metrics);
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

  Future<void> _syncPlaylistHeadersStrict(_SyncRunMetrics metrics) async {
    final playlists = await _withRetry(
      _api.getPlaylists,
      metrics: metrics,
      endpoint: 'getPlaylists',
    );
    final serverConfig = await _serverConfigRepository.getActiveServer();
    final serverId = serverConfig?.id;
    final observedAt = DateTime.now();
    final evidenceById = <String, String>{};
    final workById = <String, LibrarySyncWorkTableData?>{};
    final existing = <String, PlaylistsTableData>{
      for (final playlist in await _database.playlistDao.getAllPlaylists())
        playlist.id: playlist,
    };
    final cachedSongCounts = await _database.playlistDao
        .getPlaylistSongCounts();
    final serverIds = playlists.map((playlist) => playlist.id).toSet();
    final changedPlaylistIds = <String>{};
    for (final playlist in playlists) {
      final work = serverId == null
          ? null
          : await _database.librarySyncDao.getWork(
              serverId: serverId,
              kind: LibrarySyncPlanKind.targetedHydration.name,
              entityId: librarySyncTargetWorkKey(
                LibrarySyncTarget.playlist(playlist.id),
              ),
            );
      workById[playlist.id] = work;
      final evidence = sha256
          .convert(
            utf8.encode(
              jsonEncode(playlist.copyWith(entries: const []).toJson()),
            ),
          )
          .toString();
      evidenceById[playlist.id] = evidence;
      String? previousEvidence;
      try {
        final checkpoint = jsonDecode(work?.checkpointJson ?? '{}');
        if (checkpoint is Map && checkpoint['evidence'] is String)
          previousEvidence = checkpoint['evidence'] as String;
      } on FormatException {
        /* Legacy work will acquire evidence on this observation. */
      }
      final contentDue =
          playlist.changed == null &&
          work?.status == 'completed' &&
          observedAt.difference(work!.updatedAt) >= const Duration(hours: 12);
      final current = existing[playlist.id];
      final cachedSongCount = cachedSongCounts[playlist.id] ?? 0;
      final expectedSongCount = playlist.songCount;
      if (current == null ||
          previousEvidence != evidence ||
          contentDue ||
          _playlistHeaderChanged(current, playlist) ||
          (expectedSongCount != null && expectedSongCount != cachedSongCount)) {
        if (expectedSongCount != 0 || cachedSongCount > 0)
          changedPlaylistIds.add(playlist.id);
      }
    }
    await _database.playlistDao.reconcileServerPlaylists(
      _toPlaylistCompanions(playlists),
      serverIds.toList(growable: false),
    );
    metrics.addDbWriteBatch();

    if (serverId != null) {
      final removedIds = existing.keys
          .where((id) => !serverIds.contains(id))
          .toList(growable: false);
      await _database.librarySyncDao.deleteEntityWork(
        serverId: serverId,
        kind: LibrarySyncPlanKind.targetedHydration.name,
        entityIds: <String>{
          ...removedIds,
          ...removedIds.map(
            (id) => librarySyncTargetWorkKey(LibrarySyncTarget.playlist(id)),
          ),
        },
      );
      for (final playlistId in changedPlaylistIds) {
        final target = LibrarySyncTarget.playlist(playlistId);
        await _database.librarySyncDao.enqueueWork(
          serverId: serverId,
          kind: LibrarySyncPlanKind.targetedHydration.name,
          entityId: librarySyncTargetWorkKey(target),
          priority: 30,
          reactivateTerminal: workById[playlistId]?.status == 'completed',
          evidenceVersion: evidenceById[playlistId]!,
          checkpointJson: jsonEncode(<String, String>{
            'targetKind': target.kind.name,
            'evidence': evidenceById[playlistId]!,
          }),
        );
      }
    }
    metrics.playlistHeadersSynchronized = true;
  }

  bool _playlistHeaderChanged(
    PlaylistsTableData current,
    Playlist remote,
  ) {
    return current.name != remote.name ||
        current.songCount != remote.songCount ||
        current.duration != remote.duration ||
        current.owner != remote.owner ||
        current.isPublic != remote.isPublic ||
        current.coverArt != remote.coverArt ||
        current.comment != remote.comment;
  }

  Future<LibrarySyncState> _hydratePendingSongs({
    required LibrarySyncState state,
    required Iterable<String> priorityAlbumIds,
    required String? serverCapabilitiesJson,
    required String? storedBulkSongSearchQuery,
    required Iterable<String> excludedAlbumIds,
    Iterable<String>? restrictedAlbumIds,
    int? catalogGeneration,
    int? candidateServerId,
    required _SyncRunMetrics metrics,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final candidateMode =
        candidateServerId != null && catalogGeneration != null;
    final pendingAlbumIds =
        (candidateMode
                ? await _database.librarySyncCandidateDao.getPendingAlbumIds(
                    serverId: candidateServerId,
                    generation: catalogGeneration,
                  )
                : await _database.libraryDao.getPendingHydrationAlbumIds())
            .toSet()
          ..removeAll(_normalizeAlbumIds(excludedAlbumIds));
    if (restrictedAlbumIds != null) {
      pendingAlbumIds.retainAll(_normalizeAlbumIds(restrictedAlbumIds));
    }
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
    final validArtistIds = candidateMode
        ? await _database.librarySyncCandidateDao.getArtistIds(
            serverId: candidateServerId,
            generation: catalogGeneration,
          )
        : await _database.libraryDao.getArtistIds();
    final expectedSongCounts = candidateMode
        ? await _database.librarySyncCandidateDao.getAlbumSongCounts(
            serverId: candidateServerId,
            generation: catalogGeneration,
            albumIds: pendingAlbumIds,
          )
        : await _database.libraryDao.getAlbumSongCountsByIds(pendingAlbumIds);

    var processed = 0;
    var pendingRemaining = pending;
    final hydrationStopwatch = Stopwatch()..start();
    // A user-requested full catalog repair keeps a bounded higher concurrency
    // for its getAlbum fallback while audio is active, rather than collapsing
    // to the ordinary two-request interactive cap near completion.
    final fullCatalogHydration = candidateMode;
    final concurrencyController = _AdaptiveHydrationConcurrency(
      initial: fullCatalogHydration
          ? _fullCatalogAlbumConcurrency
          : _albumConcurrency,
      min: 1,
      max: fullCatalogHydration
          ? _fullCatalogMaxHydrationConcurrency
          : _maxHydrationConcurrency,
    );
    var current = _withMetrics(
      state.copyWith(
        stage: LibrarySyncStage.fetchingSongs,
        metadataReady: true,
        isHydrating: true,
        fastPathActive: false,
        songIndexEntriesScanned: 0,
        processed: 0,
        total: pending,
        hydratedAlbums: 0,
        pendingHydrationCount: pending,
      ),
      metrics,
    );
    onProgress?.call(current);

    Future<void> publishProgress(Iterable<String> hydratedAlbumIds) async {
      _ensureBackgroundWorkAllowed();
      final hydratedCount = hydratedAlbumIds.length;
      if (hydratedCount == 0) {
        return;
      }
      processed += hydratedCount;
      pendingRemaining -= hydratedCount;
      for (final albumId in hydratedAlbumIds) {
        pendingAlbumIds.remove(albumId);
        prioritized.remove(albumId);
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

    Future<void> publishSongIndexProgress(int scannedEntries) async {
      current = _withMetrics(
        current.copyWith(
          metadataReady: true,
          isHydrating: true,
          fastPathActive: true,
          songIndexEntriesScanned: scannedEntries,
        ),
        metrics,
      );
      onProgress?.call(current);
    }

    Future<void> processAlbumBatch(_AlbumBatchFetchResult batchResult) async {
      if (batchResult.requeueAlbumIds.isNotEmpty) {
        for (final albumId in batchResult.requeueAlbumIds) {
          if (pendingAlbumIds.remove(albumId)) {
            prioritized.remove(albumId);
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
          catalogGeneration: catalogGeneration,
        );
        hydratedAlbumIds.add(detail.id);
      }

      if (candidateMode) {
        await _database.librarySyncCandidateDao.replaceSongsForAlbums(
          serverId: candidateServerId,
          generation: catalogGeneration,
          songsByAlbum: songsByAlbum,
        );
        await _database.librarySyncCandidateDao.markAlbumsHydrated(
          serverId: candidateServerId,
          generation: catalogGeneration,
          albumIds: hydratedAlbumIds,
        );
      } else {
        final canonicalSongIds = songsByAlbum.values
            .expand((songs) => songs)
            .where((song) => song.id.present)
            .map((song) => song.id.value)
            .toSet();
        final sameIdProvisionalSongs =
            (await _database.libraryDao.getSongsByIds(canonicalSongIds))
                .where((song) => song.isProvisional)
                .map((song) => song.id)
                .toSet();
        await _database.libraryDao.reconcileSongsForAlbumsChunk(
          songsByAlbum,
          markAlbumsHydrated: true,
          snapshotStartedAt: state.startedAt,
          serverId: (await _serverConfigRepository.getActiveServer())?.id,
        );
        await _reconcileHydratedSongIds(
          canonicalSongIds: canonicalSongIds,
          sameIdProvisionalSongs: sameIdProvisionalSongs,
          metrics: metrics,
        );
      }
      metrics.addDbWriteBatch();
      await publishProgress(hydratedAlbumIds);
    }

    // OpenSubsonic defines an empty search3 query as the portable all-library
    // query. Older Navis releases persisted `*` after probing legacy servers;
    // do not let that non-standard, potentially unbounded search keep a full
    // repair from reaching the authoritative getAlbum fallback.
    final preferredBulkQuery = storedBulkSongSearchQuery == ''
        ? storedBulkSongSearchQuery
        : null;
    if (storedBulkSongSearchQuery != null && preferredBulkQuery == null) {
      final clearedCapabilitiesJson = _mergeStoredBulkSongSearchQuery(
        serverCapabilitiesJson,
        null,
      );
      if (clearedCapabilitiesJson != serverCapabilitiesJson) {
        await _serverConfigRepository.updateCapabilitiesJson(
          clearedCapabilitiesJson,
        );
        metrics.addDbWriteBatch();
      }
    }
    final permitsBulk =
        candidateMode &&
        (_activeExecutionPlan == null ||
            _activeExecutionPlan!.budget.allowedEndpoints.contains(
              SyncEndpoint.bulkSongs,
            ));
    final bulkQuery = permitsBulk
        ? await _probeBulkSongFastPath(
            pendingAlbumIds: pendingAlbumIds,
            preferredQuery: preferredBulkQuery,
            metrics: metrics,
          )
        : null;
    var bulkIndexCompleted = false;
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
          catalogGeneration: catalogGeneration,
          candidateServerId: candidateServerId,
          metrics: metrics,
          onHydratedChunk: publishProgress,
          onSongIndexProgress: publishSongIndexProgress,
        );
        bulkIndexCompleted = true;
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
        if (bulkQuery == preferredBulkQuery) {
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

    // A server-capped bulk index can omit a stable tail of an otherwise
    // complete library. Reuse locally authoritative tracks only for candidate
    // albums whose complete metadata and song count still match. This keeps
    // later full repairs fast without masking new or changed albums, which
    // remain on the bounded getAlbum fallback.
    if (candidateMode &&
        bulkIndexCompleted &&
        pendingAlbumIds.isNotEmpty &&
        _activeExecutionPlan?.kind != SyncExecutionPlanKind.repairLibrary) {
      final carriedAlbumIds = await _database.librarySyncCandidateDao
          .carryForwardPendingAlbums(
            serverId: candidateServerId,
            generation: catalogGeneration,
            markHydrated: true,
          );
      if (carriedAlbumIds.isNotEmpty) {
        metrics.addDbWriteBatch();
        current = _withMetrics(
          current.copyWith(
            carriedForwardEntityCount:
                current.carriedForwardEntityCount + carriedAlbumIds.length,
          ),
          metrics,
        );
        await publishProgress(carriedAlbumIds);
      }
    }

    while (pendingAlbumIds.isNotEmpty) {
      _checkCancelled();
      final chunk = await _nextPendingHydrationChunk(
        prioritizedAlbumIds: prioritized,
        limit:
            SyncRequestScope.current?.hydrationBatchLimit(writeChunkSize) ??
            writeChunkSize,
        candidateServerId: candidateServerId,
        catalogGeneration: catalogGeneration,
        // Exclude details deferred earlier in this pass. Re-selecting the
        // same failed row from the database would starve the remaining IDs.
        restrictedAlbumIds: [
          ...prioritized.where(pendingAlbumIds.contains),
          ...pendingAlbumIds,
        ],
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

    final remainingPending = candidateMode
        ? await _database.librarySyncCandidateDao.countPendingAlbums(
            serverId: candidateServerId,
            generation: catalogGeneration,
          )
        : await _database.libraryDao.countPendingHydrationAlbums();
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

  Future<List<String>> _nextPendingHydrationChunk({
    required List<String> prioritizedAlbumIds,
    required int limit,
    int? candidateServerId,
    int? catalogGeneration,
    Iterable<String>? restrictedAlbumIds,
  }) async {
    final restricted = restrictedAlbumIds == null
        ? null
        : _normalizeAlbumIds(restrictedAlbumIds);
    if (restricted != null) {
      if (candidateServerId != null && catalogGeneration != null) {
        return _database.librarySyncCandidateDao.getPendingAlbumIds(
          serverId: candidateServerId,
          generation: catalogGeneration,
          preferredIds: restricted,
          limit: limit,
        );
      }
      return (await _database.libraryDao.getPendingHydrationAlbumsByIds(
        restricted,
        limit: limit,
      )).map((album) => album.id).toList(growable: false);
    }
    if (candidateServerId != null && catalogGeneration != null) {
      return _database.librarySyncCandidateDao.getPendingAlbumIds(
        serverId: candidateServerId,
        generation: catalogGeneration,
        preferredIds: prioritizedAlbumIds,
        limit: limit,
      );
    }
    if (prioritizedAlbumIds.isNotEmpty) {
      final prioritizedChunk = await _database.libraryDao
          .getPendingHydrationAlbumsByIds(
            prioritizedAlbumIds,
            limit: limit,
          );
      if (prioritizedChunk.isNotEmpty) {
        return prioritizedChunk.map((album) => album.id).toList();
      }
    }
    final albums = await _database.libraryDao.getPendingHydrationAlbums(
      limit: limit,
    );
    return albums.map((album) => album.id).toList();
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
    int? catalogGeneration,
    int? candidateServerId,
    required _SyncRunMetrics metrics,
    required Future<void> Function(Iterable<String> hydratedAlbumIds)
    onHydratedChunk,
    required Future<void> Function(int scannedEntries) onSongIndexProgress,
  }) async {
    final snapshotStartedAt = DateTime.now();
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
      if (candidateServerId != null && catalogGeneration != null) {
        await _database.librarySyncCandidateDao.markAlbumsHydrated(
          serverId: candidateServerId,
          generation: catalogGeneration,
          albumIds: ids,
        );
      } else {
        await _database.libraryDao.markAlbumsSongsHydratedByIds(ids);
      }
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
          catalogGeneration: catalogGeneration,
        );
      }
      if (candidateServerId != null && catalogGeneration != null) {
        await _database.librarySyncCandidateDao.replaceSongsForAlbums(
          serverId: candidateServerId,
          generation: catalogGeneration,
          songsByAlbum: songsByAlbum,
        );
      } else {
        final canonicalSongIds = songsByAlbum.values
            .expand((songs) => songs)
            .where((song) => song.id.present)
            .map((song) => song.id.value)
            .toSet();
        final sameIdProvisionalSongs =
            (await _database.libraryDao.getSongsByIds(canonicalSongIds))
                .where((song) => song.isProvisional)
                .map((song) => song.id)
                .toSet();
        await _database.libraryDao.reconcileSongsForAlbumsChunk(
          songsByAlbum,
          snapshotStartedAt: snapshotStartedAt,
          serverId: (await _serverConfigRepository.getActiveServer())?.id,
        );
        await _reconcileHydratedSongIds(
          canonicalSongIds: canonicalSongIds,
          sameIdProvisionalSongs: sameIdProvisionalSongs,
          metrics: metrics,
        );
      }
      metrics.addDbWriteBatch();
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
        endpoint: 'searchSongsPage',
      );

      final songs = page.songs;
      await _repairExternalSourceEvidence(songs: songs);
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
        if (isExternalCatalogSource(
          id: song.id,
          apiIsExternal: song.isExternal,
        ))
          continue;
        final albumId = (song.albumId ?? '').trim();
        if (albumId.isEmpty || !pendingAlbumIds.contains(albumId)) {
          continue;
        }
        rawSongsByAlbum.putIfAbsent(albumId, () => <Song>[]).add(song);
      }

      if (rawSongsByAlbum.isNotEmpty) {
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

      // Servers are allowed to impose a lower response cap than the requested
      // songCount. A short page is therefore not an end-of-results signal:
      // Navidrome and other Subsonic servers may return (for example) 500
      // songs for a 1,000-song request while still accepting the next offset.
      // Advancing by the returned count also keeps pagination correct for that
      // cap. An empty or repeated page above is the reliable stop condition.
      offset += songs.length;
      await onSongIndexProgress(offset);
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

  /// Captures a complete server `newest` ordering before candidate promotion.
  ///
  /// Unlike the incremental health probe, a full repair must not promote a
  /// partial or looping feed because that would leave a newly rebuilt catalog
  /// with locally invented ordering. Compatible servers may cap a non-empty
  /// response, so only an empty page terminates this scan.
  Future<void> _stageCompleteNewestRanksForCandidate({
    required int serverId,
    required int generation,
    required Set<String> candidateAlbumIds,
    required _SyncRunMetrics metrics,
  }) async {
    final checkpoint = await _database.librarySyncDao.getWork(
      serverId: serverId,
      kind: 'catalogNewestRanks',
      entityId: '$generation',
    );
    if (checkpoint?.status == 'completed') return;
    const pageSize = _newestAlbumHealthProbePageSize;
    final ranks = <String, int>{};
    final seenIds = <String>{};
    String? lastPageSignature;
    var offset = 0;

    while (true) {
      List<Album> page;
      try {
        page = await _withRetry(
          () => _api.getNewestAlbumListPage(size: pageSize, offset: offset),
          metrics: metrics,
          endpoint: 'getNewestAlbumList2',
        );
      } on Object catch (error) {
        // Servers without a newest endpoint cannot supply an ordering
        // snapshot. Keep the repair viable and use their server dates only.
        if (_isIndexesUnsupported(error)) break;
        rethrow;
      }
      if (page.isEmpty) break;
      final ids = page.map((album) => album.id.trim()).toList(growable: false);
      final signature = sha1.convert(utf8.encode(ids.join('\n'))).toString();
      if (signature == lastPageSignature ||
          ids.any((id) => id.isEmpty || !seenIds.add(id))) {
        throw StateError('Newest album pagination repeated before completion.');
      }
      lastPageSignature = signature;
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        if (candidateAlbumIds.contains(id)) {
          ranks[id] = offset + index;
        }
      }
      offset += page.length;
    }

    await _database.librarySyncCandidateDao.replaceRecentlyAddedRanks(
      serverId: serverId,
      generation: generation,
      ranks: ranks,
    );
    await _database.librarySyncDao.enqueueWork(
      serverId: serverId,
      kind: 'catalogNewestRanks',
      entityId: '$generation',
      priority: 40,
    );
    final completed = await _database.librarySyncDao.getWork(
      serverId: serverId,
      kind: 'catalogNewestRanks',
      entityId: '$generation',
    );
    if (completed != null)
      await _database.librarySyncDao.markCompleted(completed.id);
    metrics.addDbWriteBatch();
  }

  Future<Set<String>> _discoverAlbumIdsFastPath({
    required int serverId,
    required int catalogGeneration,
    required _SyncRunMetrics metrics,
    void Function({
      required int discoveredCount,
      required bool hasMorePages,
    })?
    onPageProgress,
  }) async {
    var offset = 0;
    var pageCount = 0;
    var discoveredCount = 0;
    String? lastPageSignature;

    while (true) {
      _ensureBackgroundWorkAllowed();
      pageCount++;
      if (pageCount > fastPathMaxPages) {
        throw StateError('Album fast path exceeded page limit.');
      }

      final pageKey = '$catalogGeneration:$offset';
      final existingWork = await _database.librarySyncDao.getWork(
        serverId: serverId,
        kind: 'catalogAlbumPage',
        entityId: pageKey,
      );
      if (existingWork?.status == 'completed' &&
          existingWork?.checkpointJson != null) {
        final checkpoint = _decodeCatalogPageCheckpoint(
          existingWork!.checkpointJson!,
        );
        if (checkpoint != null) {
          discoveredCount += checkpoint.count;
          lastPageSignature = checkpoint.signature;
          onPageProgress?.call(
            discoveredCount: discoveredCount,
            hasMorePages: checkpoint.hasMore,
          );
          if (!checkpoint.hasMore) {
            break;
          }
          offset += checkpoint.rawCount;
          continue;
        }
      }

      final page = await _withRetry(
        () => _api.getAlbumListPage(size: fastPathPageSize, offset: offset),
        metrics: metrics,
        endpoint: 'getAlbumListPage',
      );
      await _repairExternalSourceEvidence(albums: page);
      final catalogPage = page
          .where(
            (album) => !isExternalCatalogSource(
              id: album.id,
              apiIsExternal: album.isExternal,
            ),
          )
          .toList(growable: false);
      final signature = sha1
          .convert(utf8.encode(page.map((album) => album.id).join('\n')))
          .toString();
      if (page.isNotEmpty && signature == lastPageSignature) {
        throw StateError('Album fast path repeated a catalog page.');
      }
      lastPageSignature = signature;

      if (catalogPage.isNotEmpty) {
        await _database.librarySyncCandidateDao.upsertAlbums(
          serverId: serverId,
          generation: catalogGeneration,
          albums: await _toAlbumCompanions(
            catalogPage,
            pendingHydrationAlbumIds: catalogPage.map((album) => album.id),
            catalogGeneration: catalogGeneration,
          ),
        );
        metrics.addDbWriteBatch();
      }

      // Compatible servers can cap responses below the requested page size.
      // A short non-empty page is not EOF: advance by the returned count and
      // stop only when an empty or repeated page proves the catalog ended.
      final hasMorePages = page.isNotEmpty;
      discoveredCount += catalogPage.length;
      var work = existingWork;
      if (work == null) {
        await _database.librarySyncDao.enqueueWork(
          serverId: serverId,
          kind: 'catalogAlbumPage',
          entityId: pageKey,
          priority: 40,
        );
        work = await _database.librarySyncDao.getWork(
          serverId: serverId,
          kind: 'catalogAlbumPage',
          entityId: pageKey,
        );
      }
      if (work != null) {
        await _database.librarySyncDao.updateCheckpoint(
          work.id,
          checkpointJson: jsonEncode(<String, Object>{
            'version': 2,
            'rawCount': page.length,
            'count': catalogPage.length,
            'hasMore': hasMorePages,
            'signature': signature,
          }),
        );
        await _database.librarySyncDao.markCompleted(
          work.id,
          preserveCheckpoint: true,
        );
      }
      onPageProgress?.call(
        discoveredCount: discoveredCount,
        hasMorePages: hasMorePages,
      );

      if (!hasMorePages) {
        break;
      }
      offset += page.length;
    }

    final candidateIds = await _database.librarySyncCandidateDao.getAlbumIds(
      serverId: serverId,
      generation: catalogGeneration,
    );
    if (candidateIds.length != discoveredCount) {
      throw StateError(
        'Catalog candidate contains ${candidateIds.length} albums but its '
        'page checkpoints contain $discoveredCount.',
      );
    }
    return candidateIds;
  }

  _CatalogPageCheckpoint? _decodeCatalogPageCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      if (decoded['version'] != 2) return null;
      final rawCount = decoded['rawCount'];
      final count = decoded['count'];
      final hasMore = decoded['hasMore'];
      final signature = decoded['signature'];
      if (count is! int ||
          rawCount is! int ||
          hasMore is! bool ||
          signature is! String ||
          count < 0 ||
          rawCount < count ||
          (hasMore && rawCount <= 0) ||
          (!hasMore && rawCount != 0)) {
        return null;
      }
      return _CatalogPageCheckpoint(
        count: count,
        rawCount: rawCount,
        hasMore: hasMore,
        signature: signature,
      );
    } on FormatException {
      return null;
    }
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
    String? endpoint,
    void Function(Object error, int attempts)? onFinalFailure,
  }) async {
    // Transport owns the single immediate retry. Persisted work owns every
    // later attempt so nested loops cannot multiply requests.
    const effectiveMaxAttempts = 1;
    var attempt = 0;
    while (true) {
      _checkCancelled();
      attempt++;
      final stopwatch = Stopwatch()..start();
      try {
        final scope = SyncRequestScope.current;
        final result = scope == null
            ? await action()
            : await scope.request(endpoint ?? 'unknown', action);
        metrics.recordApiAttempt(
          elapsed: stopwatch.elapsed,
          isRetryAttempt: attempt > 1,
          endpoint: endpoint,
        );
        return result;
      } on SyncCancelledException {
        rethrow;
      } on SyncNetworkDeferredException {
        rethrow;
      } on SubsonicResponseBudgetExceededException {
        rethrow;
      } on Object catch (error) {
        metrics.recordApiAttempt(
          elapsed: stopwatch.elapsed,
          isRetryAttempt: attempt > 1,
          endpoint: endpoint,
        );
        if (!_isTransient(error) ||
            attempt >= effectiveMaxAttempts ||
            (error is SubsonicApiException &&
                error.retryAt?.isAfter(DateTime.now()) == true)) {
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
        error is SubsonicForbiddenException ||
        error is SyncNetworkDeferredException ||
        error is SubsonicResponseBudgetExceededException ||
        error is SubsonicSyncLimitException;
  }

  Future<_AlbumFetchResult> _fetchAlbumDetailResilient(
    String albumId, {
    required _SyncRunMetrics metrics,
    int? maxResponseBytes,
  }) async {
    var attempts = 1;
    try {
      final album = await _withRetry(
        () => _api.getAlbum(albumId, maxResponseBytes: maxResponseBytes),
        metrics: metrics,
        endpoint: 'getAlbum',
        onFinalFailure: (error, finalAttempts) {
          attempts = finalAttempts;
        },
      );
      final canonical = canonicalAlbumSnapshot(album, requestedId: albumId);
      metrics.incompleteAlbumIds.remove(albumId);
      return _AlbumFetchResult.success(canonical);
    } on SyncCancelledException {
      rethrow;
    } on SubsonicNotFoundException catch (error) {
      AppLogger.debug(
        'Album $albumId was not found during isolated hydration; preserving '
        'it until parent or snapshot confirmation.',
      );
      metrics.recordFailureDiagnostic(
        stage: LibrarySyncStage.fetchingSongs.name,
        endpoint: 'getAlbum',
        entityId: albumId,
        error: error,
        attempts: attempts,
      );
      return const _AlbumFetchResult.requeue();
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
      if (error is SubsonicIncompleteResponseException) {
        metrics.incompleteAlbumIds.add(albumId);
        return const _AlbumFetchResult.requeue();
      }
      if (_isTransient(error)) {
        return const _AlbumFetchResult.requeue();
      }
      metrics.recordHardAlbumFailure();
      return const _AlbumFetchResult.hardFailure();
    }
  }

  Future<_AlbumBatchFetchResult> _fetchAlbumDetailsAdaptive({
    required List<String> chunk,
    required _AdaptiveHydrationConcurrency concurrencyController,
    required _SyncRunMetrics metrics,
  }) async {
    final albums = <Album>[];
    final requeueAlbumIds = <String>[];
    final hardFailedAlbumIds = <String>[];
    var offset = 0;
    final maxResponseBytes = _meteredResponseBudgetBytes();

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
          (albumId) => _fetchAlbumDetailResilient(
            albumId,
            metrics: metrics,
            maxResponseBytes: maxResponseBytes,
          ),
        ),
      );
      batchStopwatch.stop();

      var successCount = 0;
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        final albumId = batch[index];
        switch (result.outcome) {
          case _AlbumFetchOutcome.success:
            albums.add(result.album!);
            successCount++;
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
      requeueAlbumIds: requeueAlbumIds,
      hardFailedAlbumIds: hardFailedAlbumIds,
    );
  }

  LibrarySyncState _withMetrics(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
  ) {
    lastEndpointRequestCounts = Map<String, int>.from(
      metrics.apiRequestsByEndpoint,
    );
    return state.copyWith(
      apiRequests: metrics.apiRequests,
      endpointRequests: Map<String, int>.unmodifiable(
        metrics.apiRequestsByEndpoint,
      ),
      apiRetries: metrics.apiRetries,
      apiFailures: metrics.apiFailures,
      averageLatencyMs: metrics.averageLatencyMs,
      dbWriteBatches: metrics.dbWriteBatches,
      hydrationThroughputAlbumsPerSecond:
          state.hydrationThroughputAlbumsPerSecond ??
          metrics.hydrationThroughputAlbumsPerSecond,
      canonicalizedSongCount: metrics.canonicalizedSongCount,
      ambiguousMatchCount: metrics.ambiguousMatchCount,
      starredSynchronized: metrics.starredSynchronized,
      playlistHeadersSynchronized: metrics.playlistHeadersSynchronized,
      genresSynchronized: metrics.genresSynchronized,
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
    final session = metrics.identitySession ??= await SongIdentityReconciler(
      _database.songIdentityDao,
      onBeforeRemap: onBeforeSongIdentityRemap,
      readActiveSongId: readActiveSongId,
    ).startSession();
    final before = session.summary;
    await session.reconcile(canonicalSongs);
    // Targeted hydration resolves claims per batch: the album's complete
    // song set has been observed, so two-sided uniqueness is enforced and
    // buffered claims apply before the next hydration batch runs.
    await session.finalize();
    final summary = session.summary;
    metrics.canonicalizedSongCount +=
        summary.canonicalizedSongCount -
        before.canonicalizedSongCount +
        ids.intersection(sameIdProvisionalSongs).length;
    metrics.ambiguousMatchCount +=
        summary.ambiguousMatchCount - before.ambiguousMatchCount;
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

  bool _sameStoredTimestamp(DateTime? stored, DateTime? incoming) {
    if (stored == null || incoming == null) return stored == incoming;
    // Drift stores these columns as Unix seconds. Subsecond server precision
    // must not make an unchanged header appear dirty on every observation.
    return stored.millisecondsSinceEpoch ~/ 1000 ==
        incoming.millisecondsSinceEpoch ~/ 1000;
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
        !_sameStoredTimestamp(current.starred, next.starred) ||
        current.userRating != next.userRating ||
        current.playCount != next.playCount ||
        // An omitted `created` value has no authority to clear a date we
        // already know, but a supplied value can repair a date lost by an
        // older client during an ordinary newest-feed reconciliation.
        (next.created != null &&
            !_sameStoredTimestamp(current.serverCreatedAt, next.created)) ||
        !_artistListsEqual(current.artists, next.artists);
  }

  bool _artistMetadataChanged(ArtistsTableData current, Artist next) {
    return current.name != next.name ||
        current.albumCount != next.albumCount ||
        current.coverArt != next.coverArt ||
        !_sameStoredTimestamp(current.starred, next.starred) ||
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
    return !current.songsHydrated ||
        current.name != next.name ||
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

  List<ArtistsTableCompanion> _toArtistCompanions(
    List<Artist> artists, {
    int? catalogGeneration,
  }) {
    return artists
        .map(
          (artist) => ArtistsTableCompanion.insert(
            id: artist.id,
            name: artist.name,
            albumCount: Value(artist.albumCount),
            coverArt: Value(artist.coverArt),
            starred: Value(artist.starred),
            artistMbid: Value(artist.musicBrainzId),
            isExternal: Value(
              isExternalCatalogSource(
                id: artist.id,
                apiIsExternal: artist.isExternal,
              ),
            ),
            catalogGeneration: catalogGeneration == null
                ? const Value.absent()
                : Value(catalogGeneration),
          ),
        )
        .toList(growable: false);
  }

  Future<List<AlbumsTableCompanion>> _toAlbumCompanions(
    List<Album> albums, {
    Iterable<String> pendingHydrationAlbumIds = const <String>[],
    int? catalogGeneration,
    bool inheritExternalWhenMissing = false,
    Map<String, int> newestRanks = const <String, int>{},
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
            releaseMbid: Value(row.releaseMbid),
            recentlyAddedRank: newestRanks.containsKey(row.id)
                ? Value(newestRanks[row.id]!)
                : const Value.absent(),
            isExternal: Value(
              isExternalCatalogSource(
                id: row.id,
                apiIsExternal:
                    row.apiIsExternal ??
                    (inheritExternalWhenMissing ? true : null),
              ),
            ),
            catalogGeneration: catalogGeneration == null
                ? const Value.absent()
                : Value(catalogGeneration),
          ),
        )
        .toList(growable: false);
  }

  Future<List<SongsTableCompanion>> _toSongCompanions(
    List<Song> songs, {
    String? defaultAlbumId,
    required Set<String> validArtistIds,
    int? catalogGeneration,
    bool inheritExternalWhenMissing = false,
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
            isExternal: Value(
              isExternalCatalogSource(
                id: row.id,
                apiIsExternal:
                    row.apiIsExternal ??
                    (inheritExternalWhenMissing ? true : null),
              ),
            ),
            replayGainTrackGain: Value(row.replayGainTrackGain),
            replayGainAlbumGain: Value(row.replayGainAlbumGain),
            replayGainTrackPeak: Value(row.replayGainTrackPeak),
            replayGainAlbumPeak: Value(row.replayGainAlbumPeak),
            catalogGeneration: catalogGeneration == null
                ? const Value.absent()
                : Value(catalogGeneration),
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
  SongIdentityReconciliationSession? identitySession;
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
  bool starredSynchronized = false;
  bool playlistHeadersSynchronized = false;
  bool genresSynchronized = false;
  String? skippedReason;
  final Map<String, int> apiRequestsByEndpoint = <String, int>{};
  final List<_SyncFailureDiagnostic> failureDiagnostics =
      <_SyncFailureDiagnostic>[];
  final Set<String> incompleteAlbumIds = <String>{};
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
    // Request latency alone is not congestion. Reducing parallelism on a
    // healthy but high-latency server turns a large repair into a serial
    // getAlbum crawl. Back off only on an actual transport retry; otherwise
    // continue probing toward the bounded platform concurrency limit.
    if (averageLatencyMs <= 0) return;
    if (averageLatencyMs <= 450) {
      _increase(by: 2);
      return;
    }
    _increase(by: 1);
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
    this.releaseMbid,
    this.apiIsExternal,
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

  /// OpenSubsonic MusicBrainz release ID. Null on standard Subsonic servers.
  final String? releaseMbid;
  final bool? apiIsExternal;
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
    this.apiIsExternal,
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
  final bool? apiIsExternal;
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
            releaseMbid: json['musicBrainzId'] as String?,
            apiIsExternal: json['isExternal'] as bool?,
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
            apiIsExternal: json['isExternal'] as bool?,
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
    SyncNetworkDeferredException() => 'Sync deferred by network policy.',
    SubsonicResponseBudgetExceededException() =>
      'Sync deferred: response exceeded the mobile-data budget.',
    SubsonicAuthException() => 'Authentication failed while syncing metadata.',
    SubsonicConnectionException() =>
      'Connection failed while syncing metadata. Retrying later may help.',
    SubsonicApiException(:final message) => message,
    _ => 'Metadata sync failed.',
  };
}
