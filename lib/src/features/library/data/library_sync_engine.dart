import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart'
    show
        BooleanExpressionOperators,
        Table,
        TableInfo,
        TableUpdate,
        Value,
        Variable;
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/api/sync_request_scope.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/sync_write_fence.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/library/data/library_catalog_diff_analyzer.dart';
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
  const new();
  @override
  String toString() => 'SyncCancelledException: sync was cancelled.';
}

/// Thrown when live network policy requires pausing background sync work.
class SyncNetworkDeferredException implements Exception {
  const new([this.message = 'Sync deferred by network policy.']);

  final String message;

  @override
  String toString() => 'SyncNetworkDeferredException: $message';
}

class _AlbumFetchResult {
  const new({this.album, this.transient = false});

  final Album? album;
  final bool transient;
}

typedef _AlbumBatchFetchResult = ({
  List<Album> albums,
  List<String> pendingAlbumIds,
});

/// Version 3 counts the albums each page added to the candidate; version 2
/// counted the page's albums, so its saved generations are never resumed.
const int _catalogPageCheckpointVersion = 3;

class _CatalogPageCheckpoint {
  const new({
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
  const new({
    required this.stage,
    required this.endpoint,
    required this.entityId,
    required this.errorType,
  });

  final String stage;
  final String endpoint;
  final String entityId;
  final String errorType;

  Map<String, Object> toJson() => <String, Object>{
    'stage': stage,
    'endpoint': endpoint,
    'entityId': entityId,
    'errorType': errorType,
  };
}

abstract class LibrarySyncEngine {
  Future<LibrarySyncState> requestSync(
    LibrarySyncRequest request, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });
}

/// Executes the immutable plan admitted by the sync coordinator.
abstract interface class SyncPlanExecutor {
  Future<LibrarySyncState> executeSyncPlan(
    SyncExecutionPlan plan, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  });

  void cancelSync();
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

class SubsonicLibrarySyncApi implements LibrarySyncApi {
  new(this._api);

  final SubsonicApiClient _api;
  final Set<CancelToken> _activeCancelTokens = {};
  bool _cancelled = false;

  Future<T> _withCancelToken<T>(
    Future<T> Function(CancelToken cancelToken) request,
  ) async {
    // Dio attaches listeners that retain responses until the token is released.
    final cancelToken = CancelToken();
    if (_cancelled) {
      cancelToken.cancel('library sync cancelled');
    }
    _activeCancelTokens.add(cancelToken);
    try {
      return await request(cancelToken);
    } finally {
      _activeCancelTokens.remove(cancelToken);
    }
  }

  @override
  Future<ScanStatus?> getScanStatusOrNull() async {
    try {
      return await _withCancelToken(
        (cancelToken) => _api.getScanStatus(cancelToken: cancelToken),
      );
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
    _cancelled = false;
  }

  @override
  void cancelActiveRequests() {
    _cancelled = true;
    for (final cancelToken in _activeCancelTokens) {
      cancelToken.cancel('library sync cancelled');
    }
  }

  @override
  Future<List<Artist>> getArtists() => _withCancelToken(
    (cancelToken) => _api.getArtists(cancelToken: cancelToken),
  );

  @override
  Future<Artist> getArtist(String id, {int? maxResponseBytes}) =>
      _withCancelToken(
        (cancelToken) => _api.getArtist(
          id,
          cancelToken: cancelToken,
          maxResponseBytes: maxResponseBytes,
        ),
      );

  @override
  Future<Album> getAlbum(String id, {int? maxResponseBytes}) =>
      _withCancelToken(
        (cancelToken) => _api.getAlbum(
          id,
          cancelToken: cancelToken,
          maxResponseBytes: maxResponseBytes,
        ),
      );

  @override
  Future<Playlist> getPlaylist(String id, {int? maxResponseBytes}) =>
      _withCancelToken(
        (cancelToken) => _api.getPlaylist(
          id,
          cancelToken: cancelToken,
          maxResponseBytes: maxResponseBytes,
        ),
      );

  @override
  Future<StarredContent> getStarredContent() => _withCancelToken(
    (cancelToken) => _api.getStarred2(cancelToken: cancelToken),
  );

  @override
  Future<SearchResult3> searchSongsPage({
    required String query,
    required int size,
    required int offset,
  }) {
    return _withCancelToken(
      (cancelToken) => _api.search3(
        query: query,
        artistCount: 0,
        albumCount: 0,
        songCount: size,
        songOffset: offset,
        cancelToken: cancelToken,
      ),
    );
  }

  @override
  Future<List<Album>> getAlbumListPage({
    required int size,
    required int offset,
  }) {
    return _withCancelToken(
      (cancelToken) => _api.getAlbumList2(
        type: 'alphabeticalByName',
        size: size,
        offset: offset,
        cancelToken: cancelToken,
      ),
    );
  }

  @override
  Future<List<Album>> getNewestAlbumListPage({
    required int size,
    required int offset,
  }) {
    return _withCancelToken(
      (cancelToken) => _api.getAlbumList2(
        type: 'newest',
        size: size,
        offset: offset,
        cancelToken: cancelToken,
      ),
    );
  }

  @override
  Future<Indexes> getIndexes({
    DateTime? ifModifiedSince,
    bool disableRetry = false,
  }) => _withCancelToken(
    (cancelToken) => _api.getIndexes(
      ifModifiedSince: ifModifiedSince,
      cancelToken: cancelToken,
      disableRetry: disableRetry,
    ),
  );

  @override
  Future<List<Playlist>> getPlaylists() => _withCancelToken(
    (cancelToken) => _api.getPlaylists(cancelToken: cancelToken),
  );
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
const _libraryIncompleteAlbumEvidenceKey = 'libraryIncompleteAlbumEvidence';
const _librarySyncFailureDiagnosticsCapabilityKey =
    'librarySyncFailureDiagnostics';
const _librarySyncFailureRecordedAtCapabilityKey =
    'librarySyncFailureRecordedAt';
const _wifiFullCatalogAlbumConcurrency = 8;
const _wifiFullCatalogMaxAlbumConcurrency = 24;
const _otherFullCatalogAlbumConcurrency = 4;
const _otherFullCatalogMaxAlbumConcurrency = 12;
const _fastPathMaxPages = 200;
const _bulkSearchMaxPages = 200;
const _bulkSearchProbeQueries = <String>[''];
const _defaultHealthProbeStaleAfter = Duration(hours: 12);
const _libraryDiscoveryDebtStreakCapabilityKey = 'libraryDiscoveryDebtStreak';
const _libraryScanDeferralStreakCapabilityKey = 'libraryScanDeferralStreak';

/// Consecutive scan-churn deferrals after which a settled server releases
/// the withheld promotion. Without a cap, a server that rescans constantly
/// (for example on a ~30-minute churn cycle) can defer full-sync promotion
/// indefinitely.
const _maxScanDeferralStreak = 3;

const _indexesCapabilityRetryAfter = Duration(days: 1);
const _normalArtistVerificationLimit = 48;
const _cellularManualArtistVerificationLimit = 24;
const _compatibilityArtistVerificationLimit = 24;
const _newestAlbumHealthProbePageSize = 100;
const _meteredManualNewestAlbumHealthProbePageSize = 50;
const _meteredManualAlbumHydrationLimit = 3;

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

const _clearPendingVerification = <String, Object?>{
  _libraryPendingFingerprintCapabilityKey: null,
  _libraryPendingCursorCapabilityKey: null,
  _libraryPendingOffsetCapabilityKey: null,
  _libraryPendingArtistIdsCapabilityKey: null,
};

Map<String, Object?> _pendingVerificationCapabilities({
  required String fingerprint,
  required DateTime? cursor,
  required int offset,
  required List<String> artistIds,
}) => {
  _libraryPendingFingerprintCapabilityKey: fingerprint,
  _libraryPendingCursorCapabilityKey: cursor,
  _libraryPendingOffsetCapabilityKey: offset,
  _libraryPendingArtistIdsCapabilityKey: jsonEncode(artistIds),
  _libraryFreshnessCapabilityKey: LibrarySyncFreshness.verificationPending.name,
};

String? _mergeNavisCapabilities(
  String? capabilitiesJson,
  Map<String, Object?> changes,
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

  for (final entry in changes.entries) {
    final value = entry.value;
    if (value == null) {
      navisCapabilities.remove(entry.key);
    } else {
      navisCapabilities[entry.key] = switch (value) {
        DateTime() => value.toUtc().toIso8601String(),
        _ => '$value',
      };
    }
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

String _fingerprintIndexes(Indexes indexes) =>
    _fingerprintArtistIds(_indexArtistsById(indexes).keys);

Iterable<Artist> _artistsInIndexes(Indexes indexes) sync* {
  for (final group in indexes.indexes) {
    yield* group.artists;
  }
  yield* indexes.shortcut;
  yield* indexes.child;
}

Map<String, Artist> _indexArtistsById(Indexes indexes) => {
  for (final artist in _artistsInIndexes(indexes))
    if (artist.id.trim().isNotEmpty) artist.id.trim(): artist,
};

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

({List<String> artistIds, int offset, int remaining}) _readPendingVerification(
  String? capabilitiesJson,
) {
  final artistIds = _readPendingArtistIds(capabilitiesJson);
  final offset = _readNavisIntCapability(
    capabilitiesJson,
    _libraryPendingOffsetCapabilityKey,
  ).clamp(0, artistIds.length);
  return (
    artistIds: artistIds,
    offset: offset,
    remaining: artistIds.length - offset,
  );
}

class _NewestAlbumHealthProbe {
  const new({
    required this.artistIds,
    required this.discrepantAlbums,
    required this.newestRanks,
    this.debtStreak = 0,
  });

  final Set<String> artistIds;
  final List<Album> discrepantAlbums;
  final Map<String, int> newestRanks;

  /// Consecutive capped windows after this check: zero when the probe
  /// reached known content (or the feed's end), otherwise the stored streak
  /// plus one. Non-zero widens the next check's window and, at the
  /// escalation threshold, hands deep discovery to delta reconciliation.
  final int debtStreak;
}

class DriftLibrarySyncEngine implements SyncPlanExecutor {
  new({
    required this._api,
    required this._database,
    required this._serverConfigRepository,
    this.networkType = NetworkType.other,
    this._readSyncNetworkPolicy,
    this._readMeteredResponseBudgetBytes,
    this.scanSettlePollInterval = const Duration(seconds: 5),
    this.scanSettleMaxPolls = 12,
    this.fastPathPageSize = 500,
    this.bulkSearchPageSize = 1000,
    this.fallbackArtistConcurrency = 4,
    this.wifiAlbumConcurrency = 2,
    this.cellularAlbumConcurrency = 1,
    this.otherAlbumConcurrency = 2,
    this.wifiMaxAlbumConcurrency = 8,
    this.cellularMaxAlbumConcurrency = 1,
    this.otherMaxAlbumConcurrency = 4,
    this.writeChunkSize = 48,
    this.onBeforeSongIdentityRemap,
    this.readActiveSongId,
    this.readProtectedSongIds,
  });

  final LibrarySyncApi _api;
  final NavisDatabase _database;
  final ServerConfigRepository _serverConfigRepository;
  final SyncNetworkPolicy Function()? _readSyncNetworkPolicy;
  final int? Function()? _readMeteredResponseBudgetBytes;
  final NetworkType networkType;

  /// Poll cadence while waiting for a running server scan to finish before
  /// releasing a capped scan-churn deferral. Constructor-injectable so tests
  /// can bound the wait.
  final Duration scanSettlePollInterval;

  /// Upper bound on settle polls before a capped deferral stays deferred.
  final int scanSettleMaxPolls;
  final int fastPathPageSize;
  final int bulkSearchPageSize;
  final int fallbackArtistConcurrency;
  final int wifiAlbumConcurrency;
  final int cellularAlbumConcurrency;
  final int otherAlbumConcurrency;
  final int wifiMaxAlbumConcurrency;
  final int cellularMaxAlbumConcurrency;
  final int otherMaxAlbumConcurrency;
  final int writeChunkSize;
  final Future<void> Function(Map<String, String> aliases)?
  onBeforeSongIdentityRemap;
  final String? Function()? readActiveSongId;
  final Set<String> Function()? readProtectedSongIds;

  Future<LibrarySyncState>? _inFlight;
  bool _cancelled = false;
  SyncExecutionPlan? _activeExecutionPlan;

  /// Cancel any in-progress sync. Durable orchestration retains the work.
  @override
  void cancelSync() {
    _cancelled = true;
    _api.cancelActiveRequests();
  }

  /// Throws [SyncCancelledException] if [cancelSync] has been called.
  void _checkCancelled() {
    if (_cancelled) {
      throw const SyncCancelledException();
    }
  }

  void _ensureBackgroundWorkAllowed() {
    SyncRequestScope.current?.check();
    final policy = _currentSyncPolicy;
    if (!policy.isOffline &&
        (policy.allowsBackgroundSync ||
            _activeExecutionPlan?.request.grant ==
                SyncNetworkGrant.broadMeteredOnce ||
            _allowsLimitedMeteredManualDiscovery(manual: true))) {
      return;
    }
    _api.cancelActiveRequests();
    throw const SyncNetworkDeferredException();
  }

  bool _allowsLimitedMeteredManualDiscovery({required bool manual}) {
    final plan = _activeExecutionPlan;
    return manual &&
        _currentSyncPolicy.isMetered &&
        plan?.kind == LibrarySyncPlanKind.deltaReconcile &&
        plan?.request.grant == SyncNetworkGrant.boundedMeteredDiscovery;
  }

  ({int initial, int max}) _hydrationConcurrency({bool fullCatalog = false}) {
    final playing = readActiveSongId?.call() != null;
    return switch ((networkType, fullCatalog, playing)) {
      (NetworkType.wifi, true, false) => (
        initial: _wifiFullCatalogAlbumConcurrency,
        max: _wifiFullCatalogMaxAlbumConcurrency,
      ),
      (NetworkType.wifi, true, true) => (initial: 4, max: 8),
      (NetworkType.other, true, false) => (
        initial: _otherFullCatalogAlbumConcurrency,
        max: _otherFullCatalogMaxAlbumConcurrency,
      ),
      (NetworkType.other, true, true) => (initial: 2, max: 4),
      (NetworkType.offline, _, _) => (initial: 2, max: 2),
      (NetworkType.wifi, false, _) => (
        initial: wifiAlbumConcurrency,
        max: playing ? 2 : wifiMaxAlbumConcurrency,
      ),
      (NetworkType.other, false, _) => (
        initial: otherAlbumConcurrency,
        max: playing ? 2 : otherMaxAlbumConcurrency,
      ),
      (NetworkType.cellular, _, _) => (
        initial: cellularAlbumConcurrency,
        max: playing && !fullCatalog ? 2 : cellularMaxAlbumConcurrency,
      ),
    };
  }

  /// Re-announces [tables], which a target hydration wrote, once its
  /// transaction has committed. The DAO writes nest their own transactions,
  /// and drift announces a nested transaction's tables when it completes,
  /// before the outer commit; a stream re-reading then on a separate reader
  /// connection (the app's WAL read pool) sees the old rows and is not told
  /// again, so an artist or album page would wait for rows already stored.
  void _notifyCommittedTargetWrites(
    Iterable<TableInfo<Table, Object?>> tables,
  ) {
    _database.notifyUpdates(<TableUpdate>{
      for (final table in tables) TableUpdate.onTable(table),
    });
  }

  Future<LibrarySyncState> hydrateAlbum(
    String albumId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = albumId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    return await _hydrateAlbumWithinRun(
      normalizedId,
      onProgress: onProgress,
      beginRun: true,
    );
  }

  Future<LibrarySyncState> _hydrateAlbumWithinRun(
    String normalizedId, {
    LibrarySyncProgressCallback? onProgress,
    bool beginRun = false,
  }) async {
    var failureEndpoint = 'getAlbum';
    return await _runTarget(
      beginRun: beginRun,
      initial: const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingSongs,
        mode: LibrarySyncMode.incremental,
        metadataReady: true,
        isHydrating: true,
        processed: 0,
        total: 1,
        pendingHydrationCount: 1,
      ),
      pendingOnIncomplete: true,
      onProgress: onProgress,
      onFailure: (state, metrics, error) async {
        metrics.recordFailureDiagnostic(
          stage: state.stage.name,
          endpoint: failureEndpoint,
          entityId: normalizedId,
          error: error,
        );
        await _persistFailureDiagnosticsBestEffort(
          metrics,
          clearWhenEmpty: false,
        );
      },
      operation: (state, metrics) async {
        final evidence = await _pendingAlbumEvidence([normalizedId]);
        final config = await _serverConfigRepository.getActiveServer();
        final classified = _readIncompleteAlbumEvidence(
          config?.capabilitiesJson,
        )..remove(normalizedId);
        await _writeIncompleteAlbumEvidence(classified, metrics);
        try {
          final startedAt = state.startedAt!;
          // Album detail is content authority, not catalog-membership authority.
          // Preserve an already-known remote tree before inspecting a detail
          // response that may omit or contradict its external provenance.
          final existingAlbum = await _database.libraryDao.getAlbumById(
            normalizedId,
          );
          final preserveExternalTree = existingAlbum?.isExternal ?? false;
          final maxBytes = _meteredResponseBudgetBytes();
          final response = await _request(
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
            throw const SubsonicIncompleteResponseException(
              'Album details were incomplete; existing tracks were preserved.',
            );
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
          final sameIdProvisionalSongs =
              (await _database.libraryDao.getSongsByIds(
                    songs.map((song) => song.id.value),
                  ))
                  .where((song) => song.isProvisional)
                  .map((song) => song.id)
                  .toSet();
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
                    artistName:
                        existingAlbum.artistName?.trim().isNotEmpty == true
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
          _notifyCommittedTargetWrites(<TableInfo<Table, Object?>>[
            _database.artistsTable,
            _database.albumsTable,
            _database.songsTable,
          ]);
          await _database.libraryDao.cleanupRemovedCacheFiles(
            deferredCacheFiles,
          );
          metrics.addDbWriteBatch();
          return state.copyWith(processed: 1, pendingHydrationCount: 0);
        } on SubsonicIncompleteResponseException catch (error) {
          final fingerprint = evidence[normalizedId];
          if (!error.isConflictingSnapshot && fingerprint != null) {
            classified[normalizedId] = fingerprint;
            await _writeIncompleteAlbumEvidence(classified, metrics);
          }
          rethrow;
        }
      },
    );
  }

  Future<LibrarySyncState> hydrateArtist(
    String artistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = artistId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    return await _runTarget(
      initial: const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingAlbums,
        mode: LibrarySyncMode.incremental,
        metadataReady: true,
        isHydrating: true,
        total: 1,
      ),
      pendingOnIncomplete: false,
      onProgress: onProgress,
      operation: (state, metrics) async {
        final startedAt = state.startedAt!;
        final maxBytes = _meteredResponseBudgetBytes();
        final detail = await _request(
          () => _api.getArtist(normalizedId, maxResponseBytes: maxBytes),
          metrics: metrics,
          endpoint: 'getArtist',
        );
        final releaseIds = detail.albums.map((album) => album.id).toSet();
        if (detail.id != normalizedId ||
            releaseIds.any((id) => id.trim().isEmpty) ||
            releaseIds.length != detail.albums.length ||
            (detail.albumCount != null &&
                releaseIds.length < detail.albumCount!)) {
          throw const SubsonicIncompleteResponseException(
            'Artist detail identity or release count is incomplete.',
          );
        }
        final isExternalDetail = isExternalCatalogSource(
          id: detail.id,
          apiIsExternal: detail.isExternal,
        );
        if (detail.albums.isEmpty && (detail.albumCount ?? 0) > 0) {
          throw const SubsonicIncompleteResponseException(
            'Artist details were incomplete; existing albums were preserved.',
          );
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
          final albumRows =
              (await _toAlbumCompanions(
                    detail.albums,
                    pendingHydrationAlbumIds: detail.albums.map(
                      (album) => album.id,
                    ),
                    inheritExternalWhenMissing: isExternalDetail,
                  ))
                  .map(
                    (album) =>
                        album.copyWith(songsHydrated: const Value.absent()),
                  )
                  .toList(growable: false);
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
        _notifyCommittedTargetWrites(<TableInfo<Table, Object?>>[
          _database.artistsTable,
          _database.albumsTable,
        ]);
        metrics.addDbWriteBatch();
        return state.copyWith(processed: 1);
      },
    );
  }

  Future<LibrarySyncState> hydratePlaylist(
    String playlistId, {
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final normalizedId = playlistId.trim();
    if (normalizedId.isEmpty) {
      return const LibrarySyncState.idle();
    }
    return await _runTarget(
      initial: const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.fetchingSongs,
        mode: LibrarySyncMode.incremental,
        metadataReady: true,
        isHydrating: true,
        total: 1,
      ),
      pendingOnIncomplete: true,
      onProgress: onProgress,
      operation: (state, metrics) async {
        final startedAt = state.startedAt!;
        final maxBytes = _meteredResponseBudgetBytes();
        final playlist = await _request(
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
          throw const SubsonicIncompleteResponseException(
            'Playlist details were incomplete; existing tracks were preserved.',
          );
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
              readOnly: Value(playlist.readOnly),
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
        return state.copyWith(processed: 1);
      },
    );
  }

  Future<LibrarySyncState> syncStarredContent({
    LibrarySyncProgressCallback? onProgress,
  }) {
    return _runAuxiliaryTarget(
      stage: LibrarySyncStage.fetchingStarred,
      operation: _syncStarredContentStrict,
      onProgress: onProgress,
    );
  }

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
  }) => _runTarget(
    initial: LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: stage,
      mode: LibrarySyncMode.incremental,
      metadataReady: true,
    ),
    partialOnIncomplete: false,
    onProgress: onProgress,
    operation: (state, metrics) async {
      await operation(metrics);
      return state;
    },
  );

  Future<LibrarySyncState> _runTarget({
    required LibrarySyncState initial,
    required Future<LibrarySyncState> Function(
      LibrarySyncState state,
      _SyncRunMetrics metrics,
    )
    operation,
    LibrarySyncProgressCallback? onProgress,
    Future<void> Function(
      LibrarySyncState state,
      _SyncRunMetrics metrics,
      Object error,
    )?
    onFailure,
    bool beginRun = true,
    bool deferrable = true,
    bool partialOnIncomplete = true,
    bool pendingOnIncomplete = false,
  }) async {
    if (beginRun) {
      _cancelled = false;
      _api.beginRun();
    }
    final metrics = _SyncRunMetrics();
    var state = initial.copyWith(startedAt: DateTime.now());
    onProgress?.call(state);
    Object? failure;
    try {
      state = await operation(state, metrics);
    } on Object catch (error) {
      failure = error;
      if (pendingOnIncomplete &&
          (error is SubsonicIncompleteResponseException ||
              error is SubsonicResponseBudgetExceededException)) {
        state = state.copyWith(pendingHydrationCount: 1);
      }
      if (error is! SyncCancelledException &&
          error is! SyncNetworkDeferredException &&
          error is! SubsonicResponseBudgetExceededException &&
          error is! SubsonicIncompleteResponseException) {
        await onFailure?.call(state, metrics, error);
      }
    }
    state = _terminal(
      state,
      metrics,
      failure,
      deferrable: deferrable,
      partialOnIncomplete: partialOnIncomplete,
    );
    onProgress?.call(state);
    return state;
  }

  LibrarySyncState _terminal(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
    Object? error, {
    bool deferrable = true,
    bool partialOnIncomplete = true,
    LibrarySyncStatus? status,
    String? errorMessage,
  }) {
    final terminalStatus =
        status ??
        switch (error) {
          null =>
            state.status == LibrarySyncStatus.running
                ? LibrarySyncStatus.succeeded
                : state.status,
          SyncCancelledException() => LibrarySyncStatus.cancelled,
          SyncNetworkDeferredException() ||
          SubsonicResponseBudgetExceededException() ||
          SubsonicSyncLimitException() when deferrable =>
            LibrarySyncStatus.deferred,
          SubsonicIncompleteResponseException()
              when deferrable && partialOnIncomplete =>
            LibrarySyncStatus.partial,
          _ =>
            _cancelled ? LibrarySyncStatus.cancelled : LibrarySyncStatus.failed,
        };
    return _withMetrics(
      state.copyWith(
        status: terminalStatus,
        stage: LibrarySyncStage.completed,
        completedAt: DateTime.now(),
        isHydrating: false,
        errorMessage:
            errorMessage ??
            (terminalStatus == LibrarySyncStatus.cancelled
                ? 'Sync cancelled.'
                : error == null
                ? null
                : error is SubsonicIncompleteResponseException &&
                      partialOnIncomplete
                ? error.message
                : _toSafeErrorMessage(error)),
      ),
      metrics,
    );
  }

  int get _artistConcurrency {
    final albumConcurrency = _hydrationConcurrency().initial;
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

  /// Executes the plan selected at admission time.
  @override
  Future<LibrarySyncState> executeSyncPlan(
    SyncExecutionPlan plan, {
    Iterable<String> priorityAlbumIds = const <String>[],
    LibrarySyncProgressCallback? onProgress,
  }) {
    final target = plan.request.target;
    return switch (plan.kind) {
      LibrarySyncPlanKind.probe => probeCatalog(onProgress: onProgress),
      LibrarySyncPlanKind.deltaReconcile ||
      LibrarySyncPlanKind.fullRepair ||
      LibrarySyncPlanKind.catalogSnapshot ||
      LibrarySyncPlanKind.compatibilityAudit => _runWithLock(
        executionPlan: plan,
        priorityAlbumIds: priorityAlbumIds,
        onProgress: onProgress,
      ),
      LibrarySyncPlanKind.targetedHydration => switch (target.kind) {
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
        _ => _runWithLock(
          executionPlan: plan,
          priorityAlbumIds: priorityAlbumIds,
          onProgress: onProgress,
        ),
      },
    };
  }

  /// Single conditional index probe without advancing the committed cursor.
  Future<LibrarySyncState> probeCatalog({
    LibrarySyncProgressCallback? onProgress,
  }) => _runTarget(
    initial: const LibrarySyncState(
      status: LibrarySyncStatus.running,
      stage: LibrarySyncStage.fetchingArtists,
      mode: LibrarySyncMode.incremental,
      planKind: LibrarySyncPlanKind.probe,
      planReason: 'hardCatalogProbe',
      metadataReady: true,
    ),
    deferrable: false,
    onProgress: onProgress,
    operation: (state, metrics) async {
      final serverConfig = await _serverConfigRepository.getActiveServer();
      if (serverConfig == null) {
        return state.copyWith(
          status: LibrarySyncStatus.failed,
          errorMessage: 'No active server.',
        );
      }

      final current = await _withPendingAlbumDetails(
        state.copyWith(
          freshness: _readStoredLibraryFreshness(serverConfig.capabilitiesJson),
          lastSyncedAt: serverConfig.lastSynced,
        ),
        await _database.libraryDao.getPendingHydrationAlbumIds(),
        metrics,
      );
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
      return current.copyWith(
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
      );
    },
  );

  SyncNetworkPolicy get _currentSyncPolicy {
    final reader = _readSyncNetworkPolicy;
    if (reader != null) {
      return reader();
    }
    return resolveSyncNetworkPolicy(
      networkType: networkType,
      nativeMetered: networkType == NetworkType.cellular,
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

  Future<LibrarySyncState> _runWithLock({
    required SyncExecutionPlan executionPlan,
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
      plan: executionPlan,
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
    required SyncExecutionPlan plan,
    required Iterable<String> priorityAlbumIds,
    LibrarySyncProgressCallback? onProgress,
  }) async {
    final forceFull =
        plan.kind == LibrarySyncPlanKind.fullRepair ||
        plan.kind == LibrarySyncPlanKind.catalogSnapshot;
    final manual =
        forceFull ||
        (plan.kind == LibrarySyncPlanKind.deltaReconcile &&
            plan.request.intent == SyncRunIntent.manualCatalogCheck);
    final compatibilityAudit =
        plan.kind == LibrarySyncPlanKind.compatibilityAudit;
    final verificationContinuation =
        plan.kind == LibrarySyncPlanKind.targetedHydration;
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

    final mode = forceFull
        ? LibrarySyncMode.forceFull
        : LibrarySyncMode.incremental;
    final storedBulkSongSearchQuery = _readNavisStringCapability(
      serverConfig.capabilitiesJson,
      _bulkSongSearchQueryCapabilityKey,
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

    final pendingHydrationCount = await _database.libraryDao
        .countPendingHydrationAlbums();
    final pendingArtistVerificationCount = _readPendingVerification(
      serverConfig.capabilitiesJson,
    ).remaining;

    try {
      _ensureBackgroundWorkAllowed();
      if (pendingHydrationCount > 0 &&
          verificationContinuation &&
          pendingArtistVerificationCount == 0) {
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
          metrics: metrics,
          onProgress: onProgress,
        );
      }

      final catalogWasPromoted = state.mode == LibrarySyncMode.forceFull;
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

      state = await _withPendingAlbumDetails(
        state,
        await _database.libraryDao.getPendingHydrationAlbumIds(),
        metrics,
      );
      await _persistFailureDiagnosticsBestEffort(
        metrics,
        clearWhenEmpty:
            state.freshness == LibrarySyncFreshness.current &&
            state.remainingVerificationCount == 0 &&
            (state.pendingHydrationCount ?? 0) == 0,
      );

      final syncedAt = DateTime.now();
      final completedMode = state.mode ?? mode;
      final fullyCurrent =
          !state.hasBlockingPendingAlbums &&
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
        final pendingVerification = _readPendingVerification(
          deferredConfig?.capabilitiesJson,
        );
        final deferred = _terminal(
          state.copyWith(
            pendingHydrationCount: await _database.libraryDao
                .countPendingHydrationAlbums(),
            remainingVerificationCount: pendingVerification.remaining,
          ),
          metrics,
          error,
        );
        onProgress?.call(deferred);
        _logSyncSummary(state: deferred, metrics: metrics);
        return deferred;
      }
      if (_cancelled) {
        final cancelled = _terminal(
          state,
          metrics,
          error,
          status: LibrarySyncStatus.cancelled,
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
      );
      if (error is SyncLeaseLostException) {
        // The coordinator's own handler never sees this error because the
        // engine owns the run boundary; capture the current lease holder so
        // the lost-lease race is explainable from persisted evidence.
        final holder = await _database.librarySyncDao.getExecutionLease(
          serverConfig.id ?? 0,
        );
        await _database.librarySyncDao.recordOperationLedgerEntry(
          serverId: serverConfig.id ?? 0,
          operation: 'executionLeaseLost',
          reason: state.stage.name,
          details: <String, Object?>{
            'holder': holder == null
                ? null
                : <String, Object?>{
                    'ownerKind': holder.ownerKind,
                    'startedAt': holder.startedAt.toUtc().toIso8601String(),
                    'heartbeatAt': holder.heartbeatAt.toUtc().toIso8601String(),
                    'expiresAt': holder.expiresAt.toUtc().toIso8601String(),
                  },
          },
        );
        // Another run really took the lease over (ownership is the liveness
        // condition), so this run's work was fenced and safely rolled back.
        // That is contention, not a failure: defer so the coordinator
        // requeues the work, counts no failure and shows no notice.
        AppLogger.warning(
          'Library sync lease lost at stage=${state.stage}; deferring.',
        );
        final deferred = _terminal(
          state.copyWith(failureCategory: 'leaseLost'),
          metrics,
          error,
          status: LibrarySyncStatus.deferred,
          errorMessage: 'Sync paused; another sync run took over.',
        );
        onProgress?.call(deferred);
        _logSyncSummary(state: deferred, metrics: metrics);
        return deferred;
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

      final transient = _isTransient(error);
      final failed = _terminal(
        transient
            ? state.copyWith(
                failureCategory: 'transport',
                nextRetryAt: error is SubsonicApiException
                    ? error.retryAt
                    : null,
              )
            : state,
        metrics,
        error,
        status: LibrarySyncStatus.failed,
        errorMessage: transient
            ? 'Server temporarily unavailable. Sync will retry later.'
            : _toSafeErrorMessage(error),
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
      return await _request(
        _api.getArtists,
        metrics: metrics,
        endpoint: 'getArtists',
      );
    } on Object catch (getArtistsError) {
      if (!_isIndexesUnsupported(getArtistsError)) {
        rethrow;
      }

      try {
        final indexes = await _request(
          _api.getIndexes,
          metrics: metrics,
          endpoint: 'getIndexes',
        );
        final artistsById = <String, Artist>{};
        for (final artist in _artistsInIndexes(indexes)) {
          artistsById.putIfAbsent(artist.id, () => artist);
        }
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

  Future<void> _syncStarredContentStrict(_SyncRunMetrics metrics) async {
    final snapshotStartedAt = DateTime.now();
    final starred = await _request(
      _api.getStarredContent,
      metrics: metrics,
      endpoint: 'getStarredContent',
    );
    final incompleteAlbumIds = <String>{};
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
      // Field updates are partial-response-aware: only annotation fields the
      // response actually supplies are written, richer known metadata and
      // external/provisional provenance stay untouched (plan C7).
      await _database.libraryDao.upsertProvisionalArtists(
        _toArtistCompanions(starred.artists),
        snapshotStartedAt: snapshotStartedAt,
        preserveKnownMetadata: true,
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
        preserveKnownMetadata: true,
      );
      await _database.libraryDao.upsertProvisionalSongs(
        await _toSongCompanions(
          starred.songs,
          validArtistIds: referenceArtistIds,
        ),
        snapshotStartedAt: snapshotStartedAt,
        preserveKnownMetadata: true,
      );
      // Favorites whose rows lack core metadata came from a partial response
      // or an earlier provisional materialization; their albums are targeted
      // hydration candidates (plan C7).
      final incompleteAlbumRows = await _database
          .customSelect(
            'SELECT DISTINCT s.album_id AS album_id '
            'FROM songs s WHERE s.starred IS NOT NULL '
            'AND s.album_id IS NOT NULL '
            'AND (s.duration IS NULL OR s.album_name IS NULL);',
          )
          .get();
      incompleteAlbumIds.addAll(
        incompleteAlbumRows
            .map((row) => row.readNullable<String>('album_id'))
            .whereType<String>(),
      );
      final before = <String, int>{};
      final removed = <String, int>{};
      for (final (type, starredAt) in [
        ('album', albumStarredAt),
        ('artist', artistStarredAt),
        ('song', songStarredAt),
      ]) {
        final localIds = await _database.libraryDao.getStarredIds(type);
        before['${type}s'] = localIds.length;
        final confirmedAbsentIds = await _confirmedStarredAbsences(
          serverId: serverId,
          entityType: type,
          localIds: localIds,
          serverIds: starredAt.keys.toSet(),
          protectedIds: pendingByType[type]!,
        );
        removed['${type}s'] = confirmedAbsentIds.length;
        await _database.libraryDao.batchReconcileStarred(
          type,
          starredAt,
          excludeIds: pendingByType[type]!,
          confirmedAbsentIds: confirmedAbsentIds,
        );
      }
      if (serverId != null && removed.values.any((count) => count > 0)) {
        final after = <String, int>{};
        for (final type in ['album', 'artist', 'song']) {
          after['${type}s'] = (await _database.libraryDao.getStarredIds(type))
              .length;
        }
        await _database.librarySyncDao.recordOperationLedgerEntry(
          serverId: serverId,
          operation: 'starredReconciliation',
          reason: 'confirmedSecondAbsence',
          details: <String, Object?>{
            'before': before,
            'after': after,
            'removed': removed,
          },
        );
      }
    });
    metrics
      ..addDbWriteBatch()
      ..starredSynchronized = true;
    // Bounded, best-effort hydration runs outside the starred transaction so
    // a network failure cannot roll back the annotation snapshot.
    const maxStarredHydrationsPerRun = 5;
    for (final albumId in incompleteAlbumIds.take(maxStarredHydrationsPerRun)) {
      if (_cancelled) {
        break;
      }
      final result = await _hydrateAlbumWithinRun(albumId);
      if (result.status != LibrarySyncStatus.succeeded) {
        break;
      }
    }
    _checkCancelled();
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
    return await _database.librarySyncDao.observeStarredAbsences(
      serverId: serverId,
      entityType: entityType,
      ids: absentIds,
      observedAt: DateTime.now(),
    );
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
    await _updateVerificationCapabilities(<String, Object?>{
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
    }, metrics);
  }

  Future<void> _persistFailureDiagnosticsBestEffort(
    _SyncRunMetrics metrics, {
    required bool clearWhenEmpty,
  }) async {
    try {
      await _persistFailureDiagnostics(metrics, clearWhenEmpty: clearWhenEmpty);
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
    required String? capabilitiesJson,
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
    // checks retain the low-data two-page probe, widened while discovery
    // debt is outstanding, plus the look-ahead stop on the first page that
    // reaches known, unchanged content.
    final debtStreak = _readNavisIntCapability(
      capabilitiesJson,
      _libraryDiscoveryDebtStreakCapabilityKey,
    );
    final limitedMeteredManualDiscovery = _allowsLimitedMeteredManualDiscovery(
      manual: manual,
    );
    final maxPages = _activeExecutionPlan!.budget.maxNewestPages;
    final pageSize = limitedMeteredManualDiscovery
        ? _meteredManualNewestAlbumHealthProbePageSize
        : _newestAlbumHealthProbePageSize;
    final pages = <Album>[];
    final seenIds = <String>{};
    var reachedKnownContent = false;
    var reachedFeedEnd = false;
    var lastPageFull = false;
    var offset = 0;
    // A full manual check scans its whole window by contract, so it never
    // evaluates the look-ahead and carries no overlap evidence. The bounded
    // metered check does evaluate it: its cap is a budget decision, but a
    // window full of unknown content is genuine discovery evidence.
    final overlapCheckActive = !manual || limitedMeteredManualDiscovery;
    for (var pageIndex = 0; pageIndex < maxPages; pageIndex++) {
      final page = await _request(
        () => _api.getNewestAlbumListPage(size: pageSize, offset: offset),
        metrics: metrics,
        endpoint: 'getNewestAlbumList2',
      );
      if (page.isEmpty) {
        reachedFeedEnd = true;
        break;
      }
      lastPageFull = page.length >= pageSize;
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
      if (!overlapCheckActive) {
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
        reachedKnownContent = true;
        break;
      }
    }
    // A capped window that never reached known content and never saw the
    // feed's end means the local catalog is deep behind the server: record
    // discovery debt so the next check widens its window, and hand deep
    // discovery to broad reconciliation once the streak persists. A partial
    // final page already proves the feed end, so it never counts as a cap.
    final cappedWithoutOverlap =
        pages.length == maxPages * pageSize &&
        lastPageFull &&
        !reachedKnownContent;
    final nextDebtStreak =
        overlapCheckActive && cappedWithoutOverlap && !reachedFeedEnd
        ? debtStreak + 1
        : 0;

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
      debtStreak: nextDebtStreak,
    );
  }

  Future<({List<String> artistIds, int urgentCount})>
  _prioritizeVerificationArtists({
    required Map<String, Artist> snapshotArtists,
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
    return (
      artistIds: [
        ...missing,
        ...countChanged,
        ...missingFromSnapshot,
        ...remaining,
      ],
      urgentCount:
          missing.length + countChanged.length + missingFromSnapshot.length,
    );
  }

  Future<void> _refreshIndexesCursorAfterFullSync(
    _SyncRunMetrics metrics,
  ) async {
    final now = DateTime.now();
    try {
      final indexes = await _request(
        _api.getIndexes,
        metrics: metrics,
        endpoint: 'getIndexes',
      );
      final cursor = indexes.lastModified;
      if (cursor == null) {
        await _updateVerificationCapabilities(<String, Object?>{
          _libraryIndexesUnsupportedAtCapabilityKey: now,
          _libraryHealthCheckedAtCapabilityKey: now,
          ..._clearPendingVerification,
          _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
        }, metrics);
        return;
      }
      await _updateVerificationCapabilities({
        _libraryIndexesFingerprintCapabilityKey: _fingerprintIndexes(indexes),
      }, metrics);
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryIndexesCursorCapabilityKey: cursor,
        _libraryIndexesUnsupportedAtCapabilityKey: null,
        _libraryHealthCheckedAtCapabilityKey: now,
        ..._clearPendingVerification,
        _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
      }, metrics);
    } on Object catch (error) {
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      if (!_isIndexesUnsupported(error)) {
        AppLogger.warning(
          'Could not establish the post-full-sync indexes cursor: $error',
        );
      }
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryIndexesUnsupportedAtCapabilityKey: now,
        _libraryHealthCheckedAtCapabilityKey: now,
        ..._clearPendingVerification,
        _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
      }, metrics);
    }
  }

  Map<String, String> _readIncompleteAlbumEvidence(String? capabilitiesJson) {
    final raw = _readNavisStringCapability(
      capabilitiesJson,
      _libraryIncompleteAlbumEvidenceKey,
    );
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? {
              for (final entry in decoded.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : {};
    } on FormatException {
      return {};
    }
  }

  Future<void> _writeIncompleteAlbumEvidence(
    Map<String, String> evidence,
    _SyncRunMetrics metrics,
  ) => _updateVerificationCapabilities({
    _libraryIncompleteAlbumEvidenceKey: evidence.isEmpty
        ? null
        : jsonEncode(evidence),
  }, metrics);

  Future<Map<String, String>> _pendingAlbumEvidence(
    Iterable<String> ids, {
    int? candidateServerId,
    int? catalogGeneration,
  }) async {
    if (candidateServerId != null && catalogGeneration != null) {
      final rows =
          await (_database.select(_database.librarySyncCandidateAlbumsTable)
                ..where(
                  (table) =>
                      table.serverId.equals(candidateServerId) &
                      table.generation.equals(catalogGeneration) &
                      table.id.isIn(ids) &
                      table.songsHydrated.equals(false),
                ))
              .get();
      return {
        for (final row in rows)
          row.id: _albumHydrationFingerprint(
            name: row.name,
            artistId: row.artistId,
            artistName: row.artistName,
            songCount: row.songCount,
            duration: row.duration,
            coverArt: row.coverArt,
          ),
      };
    }
    final rows = await _database.libraryDao.getAlbumsByIds(ids);
    return {
      for (final row in rows)
        if (!row.songsHydrated && !row.isExternal)
          row.id: _albumHydrationFingerprint(
            name: row.name,
            artistId: row.artistId,
            artistName: row.artistName,
            songCount: row.songCount,
            duration: row.duration,
            coverArt: row.coverArt,
          ),
    };
  }

  Future<LibrarySyncState> _withPendingAlbumDetails(
    LibrarySyncState state,
    List<String> pendingAlbumIds,
    _SyncRunMetrics metrics, {
    int? candidateServerId,
    int? catalogGeneration,
  }) async {
    final config = await _serverConfigRepository.getActiveServer();
    final evidence = _readIncompleteAlbumEvidence(config?.capabilitiesJson);
    final currentEvidence = await _pendingAlbumEvidence(
      pendingAlbumIds,
      candidateServerId: candidateServerId,
      catalogGeneration: catalogGeneration,
    );
    evidence.removeWhere(
      (id, fingerprint) => currentEvidence[id] != fingerprint,
    );
    await _writeIncompleteAlbumEvidence(evidence, metrics);
    return state.copyWith(
      pendingHydrationCount: pendingAlbumIds.length,
      onlyIncompleteAlbumDetails:
          pendingAlbumIds.isNotEmpty &&
          pendingAlbumIds.every(evidence.containsKey),
    );
  }

  Future<LibrarySyncState> _finalizeHydrationOnlyVerification(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
  ) async {
    final current = await _withPendingAlbumDetails(
      state,
      await _database.libraryDao.getPendingHydrationAlbumIds(),
      metrics,
    );
    if (current.hasBlockingPendingAlbums) {
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryFreshnessCapabilityKey:
            LibrarySyncFreshness.verificationPending.name,
      }, metrics);
      return current.copyWith(
        freshness: LibrarySyncFreshness.verificationPending,
      );
    }

    final config = await _serverConfigRepository.getActiveServer();
    final pendingVerification = _readPendingVerification(
      config?.capabilitiesJson,
    );
    final remainingArtistCount = pendingVerification.remaining;
    if (remainingArtistCount > 0) {
      return current.copyWith(
        remainingVerificationCount: remainingArtistCount,
        freshness: LibrarySyncFreshness.verificationPending,
      );
    }

    if (pendingVerification.artistIds.isNotEmpty) {
      final pendingCursor = _readNavisDateCapability(
        config?.capabilitiesJson,
        _libraryPendingCursorCapabilityKey,
      );
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryIndexesCursorCapabilityKey: ?pendingCursor,
        ..._clearPendingVerification,
        _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
      }, metrics);
    } else if (_activeExecutionPlan!.budget.allowedEndpoints.contains(
      SyncEndpoint.indexes,
    )) {
      await _refreshIndexesCursorAfterFullSync(metrics);
    }
    return current.copyWith(
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
      final page = await _request(
        () => _api.getAlbumListPage(size: fastPathPageSize, offset: offset),
        metrics: metrics,
        endpoint: 'getAlbumListPage',
      );
      final signature = sha1
          .convert(utf8.encode(page.map((album) => album.id).join('\n')))
          .toString();
      if (page.length != checkpoint.rawCount ||
          signature != checkpoint.signature) {
        return false;
      }
    }
    return true;
  }

  Future<LibrarySyncState> _runFullSync({
    required LibrarySyncState state,
    required ServerConfigModel serverConfig,
    required LibrarySyncMode mode,
    required Iterable<String> priorityAlbumIds,
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
            current.copyWith(processed: discoveredCount, total: totalEstimate),
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
        current.copyWith(processed: 0, total: artists.length),
        metrics,
      );
      onProgress?.call(current);
      final artistDetails = await _mapConcurrent<Artist, Artist?>(
        artists,
        _artistConcurrency,
        (artist) async {
          final detail = await _request(
            () => _api.getArtist(artist.id),
            metrics: metrics,
            endpoint: 'getArtist',
          );
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
          return detail;
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
      storedBulkSongSearchQuery: _readNavisStringCapability(
        serverConfig.capabilitiesJson,
        _bulkSongSearchQueryCapabilityKey,
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
    await for (final page in _keysetPages(
      fetch: (afterId) => _database.librarySyncCandidateDao.getStaleSongsPage(
        serverId: serverId,
        generation: catalogGeneration,
        afterId: afterId,
        limit: 500,
      ),
      id: (row) => row.id,
    )) {
      staleSongIds.addAll(page.map((row) => row.id));
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

    if (!current.hasBlockingPendingAlbums) {
      await _refreshIndexesCursorAfterFullSync(metrics);
    } else {
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryFreshnessCapabilityKey:
            LibrarySyncFreshness.verificationPending.name,
      }, metrics);
    }

    current = _withMetrics(
      current.copyWith(
        stage: LibrarySyncStage.finalizing,
        mode: mode,
        freshness: !current.hasBlockingPendingAlbums
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
    final (token, _) = await _recordScanObservation(
      serverId: serverId,
      metrics: metrics,
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

  /// Waits a bounded number of polls for any running server scan to finish.
  /// Returns true once the server is observed quiet (or scan status is
  /// unsupported, which never blocks), false when the wait budget ran out or
  /// transport failed — the caller then defers safely.
  Future<bool> _waitForScanSettle(_SyncRunMetrics metrics) async {
    for (var attempt = 0; attempt < scanSettleMaxPolls; attempt++) {
      try {
        final status = await _api.getScanStatusOrNull();
        metrics.recordApiAttempt(
          elapsed: Duration.zero,
          endpoint: 'getScanStatus',
        );
        if (status == null || !status.scanning) {
          return true;
        }
      } on Object {
        return false;
      }
      if (attempt + 1 < scanSettleMaxPolls) {
        await Future<void>.delayed(scanSettlePollInterval);
      }
    }
    return false;
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

  /// Streams the candidate's canonical songs through [session], applies its
  /// claims, and records ambiguous matches for review.
  Future<void> _reconcileSongIdentitySession(
    SongIdentityReconciliationSession session, {
    required int serverId,
    required int generation,
    required _SyncRunMetrics metrics,
  }) async {
    await for (final page in _keysetPages(
      fetch: (afterId) => _database.librarySyncCandidateDao.getSongsPage(
        serverId: serverId,
        generation: generation,
        afterId: afterId,
        limit: writeChunkSize,
      ),
      id: (row) => row.id,
    )) {
      final canonicalSongs = await _database.libraryDao.getSongsByIds(
        page.map((song) => song.id),
      );
      await session.reconcile(canonicalSongs);
    }
    // Claims apply only after the complete replacement set has been
    // observed, so candidates contended for by several canonical rows
    // resolve as review cases instead of honoring page order.
    await session.finalize();
    final identitySummary = session.summary;
    metrics.canonicalizedSongCount += identitySummary.canonicalizedSongCount;
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
      // and let the resumable planner recollect missing work. On a server
      // that rescans continuously this could defer forever, so after a
      // bounded streak the promotion is released once the server settles.
      final serverConfig = await _serverConfigRepository.getActiveServer();
      final deferralStreak =
          _readNavisIntCapability(
            serverConfig?.capabilitiesJson,
            _libraryScanDeferralStreakCapabilityKey,
          ) +
          1;
      final scanDetails = <String, Object?>{
        'generation': generation,
        'tokenAtCollection': scanTokenAtCollection.$1,
        'tokenAtPromotion': scanAtPromotion.$1,
        'deferralStreak': deferralStreak,
      };
      final capReached = deferralStreak >= _maxScanDeferralStreak;
      var capReleased = false;
      if (capReached) {
        capReleased = await _waitForScanSettle(metrics);
      }
      if (!capReleased) {
        await _updateVerificationCapabilities(<String, Object?>{
          _libraryScanDeferralStreakCapabilityKey: deferralStreak,
        }, metrics);
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
          details: scanDetails,
        );
        AppLogger.warning(
          'Deferred catalog promotion: server scan changed during collection '
          '(streak $deferralStreak).',
        );
        return false;
      }
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryScanDeferralStreakCapabilityKey: null,
      }, metrics);
      await _database.librarySyncDao.recordOperationLedgerEntry(
        serverId: serverId,
        operation: 'catalogPromotion',
        reason: 'scanChurnCapRelease',
        details: scanDetails,
      );
      AppLogger.warning(
        'Released deferred catalog promotion after $deferralStreak '
        'consecutive scan-churn deferrals: server settled. The freshest '
        'completed snapshot wins.',
      );
    }
    // Cache files the promotion releases are deleted only after it commits,
    // including files that lose an identity remap inside it.
    final deferredCacheFiles = <String>[];
    final provisionalSongs = await _database.songIdentityDao
        .getProvisionalSongs();
    final identitySession = provisionalSongs.isEmpty
        ? null
        : await SongIdentityReconciler(
            _database.songIdentityDao,
            onBeforeRemap: onBeforeSongIdentityRemap,
            readActiveSongId: readActiveSongId,
            deferredFileDeletions: deferredCacheFiles,
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
      await for (final page in _keysetPages(
        fetch: (afterId) =>
            _database.librarySyncCandidateDao.getChangedArtistsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterId,
              limit: writeChunkSize,
            ),
        id: (row) => row.id,
      )) {
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
              catalogAvailability: const Value(null),
            ),
        ]);
      }

      await for (final page in _keysetPages(
        fetch: (afterId) =>
            _database.librarySyncCandidateDao.getChangedAlbumsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterId,
              limit: writeChunkSize,
            ),
        id: (row) => row.id,
      )) {
        changedAlbumIds.addAll(page.map((album) => album.id));
        await _database.libraryDao.upsertAlbums([
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
              catalogAvailability: const Value(null),
            ),
        ], preserveHydrationState: false);
      }

      await for (final page in _keysetPages(
        fetch: (afterId) =>
            _database.librarySyncCandidateDao.getChangedSongsPage(
              serverId: serverId,
              generation: generation,
              afterId: afterId,
              limit: writeChunkSize,
            ),
        id: (row) => row.id,
      )) {
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
              // The snapshot re-observes this row: legacy absence markers
              // clear because validated server evidence proves presence.
              serverDeletedAt: const Value(null),
              catalogAvailability: const Value(null),
              replayGainTrackGain: Value(song.replayGainTrackGain),
              replayGainAlbumGain: Value(song.replayGainAlbumGain),
              replayGainTrackPeak: Value(song.replayGainTrackPeak),
              replayGainAlbumPeak: Value(song.replayGainAlbumPeak),
            ),
        ]);
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
        'UPDATE albums SET songs_verified_at = ? WHERE id IN ( '
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
        await _reconcileSongIdentitySession(
          identitySession,
          serverId: serverId,
          generation: generation,
          metrics: metrics,
        );
      }

      final preserved = await _database.libraryDao
          .preserveCachedLegacyRowsAsProvisional(
            staleArtistIds: staleArtistIds,
            staleAlbumIds: staleAlbumIds,
            protectedSongIds: readProtectedSongIds?.call() ?? const <String>{},
          );

      await for (final staleSongs in _keysetPages(
        fetch: (afterId) => _database.librarySyncCandidateDao.getStaleSongsPage(
          serverId: serverId,
          generation: generation,
          afterId: afterId,
          limit: writeChunkSize,
        ),
        id: (row) => row.id,
      )) {
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
            ?retainedById[retainedId],
        ];
        await _database.librarySyncDao.recordRecoveryReviewBatch(
          serverId: serverId,
          retainedSongs: retainedSongs,
          evidenceGeneration: generation,
        );
      }

      // Rows this promotion just kept as provisional (downloads of rebuilt
      // albums, songs retained as unavailable) are matched to their new ids
      // now, as the next full sync would, instead of staying split until
      // then. Only promotions that kept rows pay for this pass.
      SongIdentityReconciliationSession? lateIdentitySession;
      var lateProvisionalSongs = const <SongsTableData>[];
      if (preserved.songIds.isNotEmpty || retainedUnavailableCount > 0) {
        final knownProvisionalIds = <String>{
          for (final song in provisionalSongs) song.id,
        };
        lateProvisionalSongs =
            (await _database.songIdentityDao.getProvisionalSongs())
                .where((song) => !knownProvisionalIds.contains(song.id))
                .toList(growable: false);
        if (lateProvisionalSongs.isNotEmpty) {
          lateIdentitySession = await SongIdentityReconciler(
            _database.songIdentityDao,
            onBeforeRemap: onBeforeSongIdentityRemap,
            readActiveSongId: readActiveSongId,
            deferredFileDeletions: deferredCacheFiles,
          ).startSession(provisionalSongs: lateProvisionalSongs);
          await _reconcileSongIdentitySession(
            lateIdentitySession,
            serverId: serverId,
            generation: generation,
            metrics: metrics,
          );
        }
      }

      // Album/artist relinking runs after rows are preserved as provisional
      // and the retained song set is final, but before removable stale rows
      // are deleted: unresolved entities must still be reviewable from their
      // recorded metadata, and remapped entities delete their own rows.
      final entityIdentitySummary = await EntityIdentityReconciler(_database)
          .reconcile(
            serverId: serverId,
            generation: generation,
            songAliases: <SongIdentityAlias>[
              ...?identitySession?.summary.aliases,
              ...?lateIdentitySession?.summary.aliases,
            ],
            provisionalSongs: <SongsTableData>[
              ...provisionalSongs,
              ...lateProvisionalSongs,
            ],
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
        deferredCacheFiles.addAll(
          await _database.libraryDao.deleteAlbumsByIds(removableAlbumIds),
        );
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
    // A promotion supersedes any recorded scan-churn deferral streak.
    final promotedServer = await _serverConfigRepository.getActiveServer();
    if (_readNavisIntCapability(
          promotedServer?.capabilitiesJson,
          _libraryScanDeferralStreakCapabilityKey,
        ) >
        0) {
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryScanDeferralStreakCapabilityKey: null,
      }, metrics);
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
        final fetchedIndexes = await _request(
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
          await _updateVerificationCapabilities(<String, Object?>{
            _libraryIndexesUnsupportedAtCapabilityKey: now,
          }, metrics);
        } else {
          await _updateVerificationCapabilities(<String, Object?>{
            _libraryIndexesUnsupportedAtCapabilityKey: null,
          }, metrics);
        }
      } on Object catch (error) {
        if (!_isIndexesUnsupported(error)) {
          rethrow;
        }
        AppLogger.info(
          'getIndexes is unsupported; using bounded artist and newest-album '
          'verification.',
        );
        await _updateVerificationCapabilities(<String, Object?>{
          _libraryIndexesUnsupportedAtCapabilityKey: now,
        }, metrics);
      }
    }

    final fallbackVerification = !indexesReliable;
    if (fallbackVerification &&
        networkType == NetworkType.cellular &&
        !manual) {
      metrics.skippedReason = 'verificationRequiresNonCellular';
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryFreshnessCapabilityKey:
            LibrarySyncFreshness.repairRecommended.name,
      }, metrics);
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
    } else if (!_activeExecutionPlan!.budget.allowedEndpoints.contains(
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
      final artists = await _request(
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
    final discoveryDebtStreak = _readNavisIntCapability(
      capabilitiesJson,
      _libraryDiscoveryDebtStreakCapabilityKey,
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
        _activeExecutionPlan!.budget.maxNewestPages > 0 ||
        lastHealthCheck == null ||
        // Outstanding discovery debt keeps the newest-feed probe on the
        // schedule: the window must reach known content before freshness can
        // be reported honestly.
        discoveryDebtStreak > 0 ||
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
      healthProbe = await _runNewestAlbumHealthProbe(
        metrics,
        manual: manual,
        capabilitiesJson: capabilitiesJson,
      );
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryHealthCheckedAtCapabilityKey: now,
        _libraryDiscoveryDebtStreakCapabilityKey: healthProbe.debtStreak > 0
            ? healthProbe.debtStreak
            : null,
      }, metrics);
      current = _withMetrics(
        current.copyWith(probeDiscoveryDebtStreak: healthProbe.debtStreak),
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
        storedBulkSongSearchQuery: null,
        excludedAlbumIds: const <String>{},
        metrics: metrics,
        onProgress: onProgress,
      );
      current = await _withPendingAlbumDetails(
        current,
        await _database.libraryDao.getPendingHydrationAlbumIds(),
        metrics,
      );
      if (current.hasBlockingPendingAlbums) {
        metrics.skippedReason = 'meteredManualDiscoveryBounded';
      }
      return _withMetrics(
        current.copyWith(
          stage: LibrarySyncStage.finalizing,
          remainingVerificationCount: 0,
          freshness: current.hasBlockingPendingAlbums
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
    final pendingVerification = _readPendingVerification(capabilitiesJson);
    final storedPendingArtistIds = pendingVerification.artistIds;
    final storedPendingOffset = pendingVerification.offset;
    final samePendingSnapshot =
        pendingFingerprint == indexesFingerprint &&
        storedPendingArtistIds.isNotEmpty &&
        (targetCursor == null ||
            pendingTargetCursor == null ||
            targetCursor.toUtc() == pendingTargetCursor.toUtc());

    final prioritizedArtists = await _prioritizeVerificationArtists(
      snapshotArtists: snapshotArtists,
    );
    final fullAuditArtistIds = prioritizedArtists.artistIds;
    final urgentArtistIds = fullAuditArtistIds.take(
      prioritizedArtists.urgentCount,
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
    final boundedLimit =
        _activeExecutionPlan!.request.intent ==
            SyncRunIntent.automaticCatalogCheck
        ? 24
        : 48;
    if (passLimit > boundedLimit) passLimit = boundedLimit;
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
        void publishArtistProgress() {
          current = _withMetrics(
            current.copyWith(processed: (current.processed ?? 0) + 1),
            metrics,
          );
          onProgress?.call(current);
        }

        try {
          final artist = await _request(
            () => _api.getArtist(artistId),
            metrics: metrics,
            endpoint: 'getArtist',
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
      final existing = await _database.libraryDao.getAlbumsByArtist(entry.key);
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
        await _updateVerificationCapabilities(
          _pendingVerificationCapabilities(
            fingerprint: indexesFingerprint,
            cursor: targetCursor,
            offset: nextPendingOffset,
            artistIds: orderedArtistIds,
          ),
          metrics,
        );
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

    if (interruptedPass != null) {
      Error.throwWithStackTrace(interruptedPass!, StackTrace.current);
    }

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
      storedBulkSongSearchQuery: _readNavisStringCapability(
        serverConfig.capabilitiesJson,
        _bulkSongSearchQueryCapabilityKey,
      ),
      excludedAlbumIds: hydratedWithoutSongRefresh,
      metrics: metrics,
      onProgress: onProgress,
    );

    await _updateVerificationCapabilities({
      _libraryIndexesFingerprintCapabilityKey: indexesFingerprint,
    }, metrics);
    final hasPendingVerification =
        remainingVerificationCount > 0 || current.hasBlockingPendingAlbums;
    if (hasPendingVerification) {
      await _updateVerificationCapabilities(
        _pendingVerificationCapabilities(
          fingerprint: indexesFingerprint,
          cursor: targetCursor,
          offset: nextPendingOffset,
          artistIds: orderedArtistIds,
        ),
        metrics,
      );
    } else {
      await _updateVerificationCapabilities(<String, Object?>{
        _libraryIndexesCursorCapabilityKey: ?targetCursor,
        ..._clearPendingVerification,
        _libraryFreshnessCapabilityKey: LibrarySyncFreshness.current.name,
      }, metrics);
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

  /// Makes the bounded `newest` feed useful as a direct change path.
  ///
  /// `getIndexes` is intentionally only an artist-collection invalidation
  /// signal. Its contents cannot tell us which existing artist received a new
  /// album. The newest feed does, and every listed album is subsequently
  /// hydrated through the normal song and identity-reconciliation path.
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
      await _database.libraryDao.markAlbumsPendingHydrationByIds(needsTracks);
      await _database.libraryDao.replaceRecentlyAddedRanksFromNewestFeed(
        newestRanks,
        complete: false,
      );
    });
    metrics
      ..metadataChanged = true
      ..addDbWriteBatch();
  }

  Future<void> _syncPlaylistHeadersStrict(_SyncRunMetrics metrics) async {
    final mutationVersion = await _database.playlistDao.getMutationVersion();
    final playlists = await _request(
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
      for (final playlist in await _database.playlistDao.getServerPlaylists())
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
        if (checkpoint is Map && checkpoint['evidence'] is String) {
          previousEvidence = checkpoint['evidence'] as String;
        }
      } on FormatException {
        /* Legacy work will acquire evidence on this observation. */
      }
      final contentDue =
          playlist.changed == null &&
          work?.status == 'completed' &&
          observedAt.difference(work!.updatedAt) >=
              librarySyncAuxiliaryInterval;
      final current = existing[playlist.id];
      final cachedSongCount = cachedSongCounts[playlist.id] ?? 0;
      final expectedSongCount = playlist.songCount;
      if (current == null ||
          previousEvidence != evidence ||
          contentDue ||
          _playlistHeaderChanged(current, playlist) ||
          (expectedSongCount != null && expectedSongCount != cachedSongCount)) {
        if (expectedSongCount != 0 || cachedSongCount > 0) {
          changedPlaylistIds.add(playlist.id);
        }
      }
    }
    final removedIds = await _database.playlistDao.reconcileServerPlaylists(
      _toPlaylistCompanions(playlists),
      serverIds.toList(growable: false),
      mutationVersion: mutationVersion,
    );
    metrics.addDbWriteBatch();

    if (serverId != null) {
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
          evidenceVersion: evidenceById[playlistId],
          checkpointJson: jsonEncode(<String, String>{
            'targetKind': target.kind.name,
            'evidence': evidenceById[playlistId]!,
          }),
        );
      }
    }
    metrics.playlistHeadersSynchronized = true;
  }

  bool _playlistHeaderChanged(PlaylistsTableData current, Playlist remote) {
    return current.name != remote.name ||
        current.songCount != remote.songCount ||
        current.duration != remote.duration ||
        current.owner != remote.owner ||
        current.isPublic != remote.isPublic ||
        current.readOnly != remote.readOnly ||
        current.coverArt != remote.coverArt ||
        current.comment != remote.comment;
  }

  Future<LibrarySyncState> _hydratePendingSongs({
    required LibrarySyncState state,
    required Iterable<String> priorityAlbumIds,
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

    final prioritized = _normalizeAlbumIds(priorityAlbumIds)
        .where(pendingAlbumIds.contains)
        .toList(growable: true);
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
    final concurrency = _hydrationConcurrency(fullCatalog: candidateMode);
    final concurrencyController = _AdaptiveHydrationConcurrency(
      initial: concurrency.initial,
      min: 1,
      max: concurrency.max,
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
      if (batchResult.pendingAlbumIds.isNotEmpty) {
        for (final albumId in batchResult.pendingAlbumIds) {
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
      var convertedAlbums = 0;
      for (final detail in batchResult.albums) {
        songsByAlbum[detail.id] = await _toSongCompanions(
          detail.songs,
          defaultAlbumId: detail.id,
          validArtistIds: validArtistIds,
          catalogGeneration: catalogGeneration,
        );
        hydratedAlbumIds.add(detail.id);
        convertedAlbums++;
        if (convertedAlbums % 8 == 0) {
          // Keep database reads and Flutter frames responsive while a fetched
          // batch is converted; reconciliation still observes the whole batch.
          await Future<void>.delayed(Duration.zero);
        }
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
        final removedCacheFiles = await _database.libraryDao
            .reconcileSongsForAlbumsChunk(
              songsByAlbum,
              markAlbumsHydrated: true,
              snapshotStartedAt: state.startedAt,
              serverId: (await _serverConfigRepository.getActiveServer())?.id,
            );
        await _database.libraryDao.cleanupRemovedCacheFiles(removedCacheFiles);
        await _reconcileHydratedSongIds(
          canonicalSongIds: canonicalSongIds,
          sameIdProvisionalSongs: sameIdProvisionalSongs,
          metrics: metrics,
        );
      }
      metrics.addDbWriteBatch();
      await publishProgress(hydratedAlbumIds);
    }

    final preferredBulkQuery = storedBulkSongSearchQuery == '' ? '' : null;
    final permitsBulk =
        candidateMode &&
        _activeExecutionPlan!.budget.allowedEndpoints.contains(
          SyncEndpoint.bulkSongs,
        );
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
          catalogGeneration: catalogGeneration!,
          candidateServerId: candidateServerId!,
          metrics: metrics,
          onHydratedChunk: publishProgress,
          onSongIndexProgress: publishSongIndexProgress,
        );
        bulkIndexCompleted = true;
        await _updateVerificationCapabilities({
          _bulkSongSearchQueryCapabilityKey: bulkQuery,
        }, metrics);
      } on SyncCancelledException {
        rethrow;
      } on Object catch (error, stackTrace) {
        if (bulkQuery == preferredBulkQuery) {
          await _updateVerificationCapabilities({
            _bulkSongSearchQueryCapabilityKey: null,
          }, metrics);
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
    // later catalog snapshots fast without masking new or changed albums, which
    // remain on the bounded getAlbum fallback.
    if (candidateMode &&
        bulkIndexCompleted &&
        pendingAlbumIds.isNotEmpty &&
        _activeExecutionPlan!.kind != LibrarySyncPlanKind.fullRepair) {
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
        candidateServerId: candidateServerId,
        catalogGeneration: catalogGeneration,
      );

      await processAlbumBatch(batchResult);
      // Yield to the event loop between write batches so the UI can
      // render frames and respond to user input during long hydrations.
      await Future<void>.delayed(Duration.zero);
    }

    final remainingPendingIds = candidateMode
        ? await _database.librarySyncCandidateDao.getPendingAlbumIds(
            serverId: candidateServerId,
            generation: catalogGeneration,
          )
        : await _database.libraryDao.getPendingHydrationAlbumIds();
    current = await _withPendingAlbumDetails(
      current,
      remainingPendingIds,
      metrics,
      candidateServerId: candidateServerId,
      catalogGeneration: catalogGeneration,
    );
    if (current.hasBlockingPendingAlbums) {
      metrics.skippedReason = 'albumHydrationPending';
    }

    return _withMetrics(
      current.copyWith(
        metadataReady: true,
        isHydrating: false,
        fastPathActive: false,
        freshness: current.hasBlockingPendingAlbums
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
        return await _database.librarySyncCandidateDao.getPendingAlbumIds(
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
      return await _database.librarySyncCandidateDao.getPendingAlbumIds(
        serverId: candidateServerId,
        generation: catalogGeneration,
        preferredIds: prioritizedAlbumIds,
        limit: limit,
      );
    }
    if (prioritizedAlbumIds.isNotEmpty) {
      final prioritizedChunk = await _database.libraryDao
          .getPendingHydrationAlbumsByIds(prioritizedAlbumIds, limit: limit);
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
    for (final query in _bulkSearchProbeQueries) {
      if (candidateQueries.contains(query)) {
        continue;
      }
      candidateQueries.add(query);
    }
    for (final query in candidateQueries) {
      try {
        final page = await _request(
          () => _api.searchSongsPage(query: query, size: 1, offset: 0),
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
        AppLogger.debug('Bulk song probe query "$query" unavailable: $error');
      }
    }
    return null;
  }

  Future<void> _hydratePendingSongsWithBulkSearch({
    required String query,
    required Set<String> pendingAlbumIds,
    required Map<String, int?> expectedSongCounts,
    required Set<String> validArtistIds,
    required int catalogGeneration,
    required int candidateServerId,
    required _SyncRunMetrics metrics,
    required Future<void> Function(Iterable<String> hydratedAlbumIds)
    onHydratedChunk,
    required Future<void> Function(int scannedEntries) onSongIndexProgress,
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
      await _database.librarySyncCandidateDao.markAlbumsHydrated(
        serverId: candidateServerId,
        generation: catalogGeneration,
        albumIds: ids,
      );
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
      await _database.librarySyncCandidateDao.replaceSongsForAlbums(
        serverId: candidateServerId,
        generation: catalogGeneration,
        songsByAlbum: songsByAlbum,
      );
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
      if (pageCount > _bulkSearchMaxPages) {
        break;
      }

      final page = await _request(
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
        )) {
          continue;
        }
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
        page = await _request(
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
      final seenBefore = seenIds.length;
      for (var index = 0; index < ids.length; index++) {
        final id = ids[index];
        // An album already seen keeps its first rank: albums added during the
        // scan shift the list, so the album at a page boundary comes back on
        // the next page.
        if (id.isNotEmpty &&
            seenIds.add(id) &&
            candidateAlbumIds.contains(id)) {
          ranks[id] = offset + index;
        }
      }
      // A server that ignores the offset repeats its page, and one that loops
      // brings nothing new; neither would ever reach the empty last page.
      if (signature == lastPageSignature ||
          seenIds.length == seenBefore ||
          ids.any((id) => id.isEmpty)) {
        throw StateError('Newest album pagination repeated before completion.');
      }
      lastPageSignature = signature;
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
    if (completed != null) {
      await _database.librarySyncDao.markCompleted(completed.id);
    }
    metrics.addDbWriteBatch();
  }

  Future<Set<String>> _discoverAlbumIdsFastPath({
    required int serverId,
    required int catalogGeneration,
    required _SyncRunMetrics metrics,
    void Function({required int discoveredCount, required bool hasMorePages})?
    onPageProgress,
  }) async {
    var offset = 0;
    var pageCount = 0;
    var discoveredCount = 0;
    String? lastPageSignature;

    while (true) {
      _ensureBackgroundWorkAllowed();
      pageCount++;
      if (pageCount > _fastPathMaxPages) {
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

      final page = await _request(
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

      final albums = catalogPage.isEmpty
          ? const <AlbumsTableCompanion>[]
          : await _toAlbumCompanions(
              catalogPage,
              pendingHydrationAlbumIds: catalogPage.map((album) => album.id),
              catalogGeneration: catalogGeneration,
            );
      // Compatible servers can cap responses below the requested page size.
      // A short non-empty page is not EOF: advance by the returned count and
      // stop only when an empty or repeated page proves the catalog ended.
      final hasMorePages = page.isNotEmpty;
      // A page counts only the albums it adds to the candidate. When the
      // server's list shifts while Navis pages through it (an album added
      // mid-repair, or ties in name order), the album at a page boundary
      // comes back on the next page; counting it twice would fail the
      // completeness check below on every resume. The write and its
      // checkpoint commit together, so a resume never counts a page twice.
      final added = await _database.transaction(() async {
        final before = await _database.librarySyncCandidateDao.countAlbums(
          serverId: serverId,
          generation: catalogGeneration,
        );
        if (albums.isNotEmpty) {
          await _database.librarySyncCandidateDao.upsertAlbums(
            serverId: serverId,
            generation: catalogGeneration,
            albums: albums,
          );
        }
        final added =
            await _database.librarySyncCandidateDao.countAlbums(
              serverId: serverId,
              generation: catalogGeneration,
            ) -
            before;
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
              'version': _catalogPageCheckpointVersion,
              'rawCount': page.length,
              'count': added,
              'hasMore': hasMorePages,
              'signature': signature,
            }),
          );
          await _database.librarySyncDao.markCompleted(
            work.id,
            preserveCheckpoint: true,
          );
        }
        return added;
      });
      if (albums.isNotEmpty) {
        metrics.addDbWriteBatch();
      }
      discoveredCount += added;
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
      // The checkpoints disagree with the candidate rows, so a resume would
      // replay this failure for the whole resumability window. Drop both
      // sides so the next run rebuilds the candidate from fresh pages.
      await _database.transaction(() async {
        await _database.librarySyncCandidateDao.clearGeneration(
          serverId: serverId,
          generation: catalogGeneration,
        );
        await _database.librarySyncDao.clearCatalogPageWork(
          serverId: serverId,
          generation: catalogGeneration,
        );
      });
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
      if (decoded['version'] != _catalogPageCheckpointVersion) return null;
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

  Future<T> _request<T>(
    Future<T> Function() action, {
    required _SyncRunMetrics metrics,
    String? endpoint,
  }) async {
    // Transport owns the single immediate retry. Persisted work owns every
    // later attempt so nested loops cannot multiply requests.
    _checkCancelled();
    final stopwatch = Stopwatch()..start();
    try {
      final scope = SyncRequestScope.current;
      final result = scope == null
          ? await action()
          : await scope.request(endpoint ?? 'unknown', action);
      metrics.recordApiAttempt(elapsed: stopwatch.elapsed, endpoint: endpoint);
      return result;
    } on SyncCancelledException {
      rethrow;
    } on SyncNetworkDeferredException {
      rethrow;
    } on SubsonicResponseBudgetExceededException {
      rethrow;
    } on Object {
      metrics.recordApiAttempt(elapsed: stopwatch.elapsed, endpoint: endpoint);
      metrics.recordApiFailure();
      rethrow;
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
    metrics.incompleteAlbumIds.remove(albumId);
    try {
      final album = await _request(
        () => _api.getAlbum(albumId, maxResponseBytes: maxResponseBytes),
        metrics: metrics,
        endpoint: 'getAlbum',
      );
      final canonical = canonicalAlbumSnapshot(album, requestedId: albumId);
      return _AlbumFetchResult(album: canonical);
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
      );
      return const _AlbumFetchResult();
    } on Object catch (error) {
      metrics.recordFailureDiagnostic(
        stage: LibrarySyncStage.fetchingSongs.name,
        endpoint: 'getAlbum',
        entityId: albumId,
        error: error,
      );
      if (_isFatalEntityError(error)) {
        rethrow;
      }
      if (error is SubsonicIncompleteResponseException) {
        if (!error.isConflictingSnapshot) {
          metrics.incompleteAlbumIds.add(albumId);
        }
        return const _AlbumFetchResult();
      }
      if (_isTransient(error)) {
        return const _AlbumFetchResult(transient: true);
      }
      metrics.recordHardAlbumFailure();
      return const _AlbumFetchResult();
    }
  }

  Future<_AlbumBatchFetchResult> _fetchAlbumDetailsAdaptive({
    required List<String> chunk,
    required _AdaptiveHydrationConcurrency concurrencyController,
    required _SyncRunMetrics metrics,
    int? candidateServerId,
    int? catalogGeneration,
  }) async {
    final albums = <Album>[];
    final pendingAlbumIds = <String>[];
    var offset = 0;
    final maxResponseBytes = _meteredResponseBudgetBytes();

    while (offset < chunk.length) {
      final batchSize = concurrencyController.current;
      final end = (offset + batchSize) > chunk.length
          ? chunk.length
          : offset + batchSize;
      final batch = chunk.sublist(offset, end);
      offset = end;

      final evidence = await _pendingAlbumEvidence(
        batch,
        candidateServerId: candidateServerId,
        catalogGeneration: catalogGeneration,
      );
      final config = await _serverConfigRepository.getActiveServer();
      final classified = _readIncompleteAlbumEvidence(config?.capabilitiesJson)
        ..removeWhere((id, _) => batch.contains(id));
      // Revoke before requests: cancellation or a fatal outcome must not leave
      // an earlier incomplete response exempting this attempt.
      await _writeIncompleteAlbumEvidence(classified, metrics);
      final retriesBefore = SyncRequestScope.current?.retryCount ?? 0;
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
      for (final id in batch) {
        final fingerprint = evidence[id];
        if (fingerprint != null && metrics.incompleteAlbumIds.contains(id)) {
          classified[id] = fingerprint;
        }
      }
      await _writeIncompleteAlbumEvidence(classified, metrics);

      var successCount = 0;
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        final albumId = batch[index];
        final album = result.album;
        if (album != null) {
          albums.add(album);
          successCount++;
        } else {
          pendingAlbumIds.add(albumId);
        }
      }

      final avgLatencyMs = successCount == 0
          ? 0
          : (batchStopwatch.elapsedMilliseconds ~/ successCount);
      concurrencyController.observeBatch(
        averageLatencyMs: avgLatencyMs,
        hadTransientPressure:
            results.any((result) => result.transient) ||
            (SyncRequestScope.current?.retryCount ?? 0) > retriesBefore,
      );
    }

    return (albums: albums, pendingAlbumIds: pendingAlbumIds);
  }

  LibrarySyncState _withMetrics(
    LibrarySyncState state,
    _SyncRunMetrics metrics,
  ) {
    return state.copyWith(
      apiRequests: metrics.apiRequests,
      endpointRequests: Map<String, int>.unmodifiable(
        metrics.apiRequestsByEndpoint,
      ),
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

  String _albumHydrationFingerprint({
    required String name,
    required String? artistId,
    required String? artistName,
    required int? songCount,
    required int? duration,
    required String? coverArt,
  }) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            name,
            artistId,
            artistName,
            songCount,
            duration,
            coverArt,
          ]),
        ),
      )
      .toString();

  bool _albumRequiresSongHydration(AlbumsTableData current, Album next) {
    return !current.songsHydrated ||
        _albumHydrationFingerprint(
              name: current.name,
              artistId: current.artistId,
              artistName: current.artistName,
              songCount: current.songCount,
              duration: current.duration,
              coverArt: current.coverArt,
            ) !=
            _albumHydrationFingerprint(
              name: next.name,
              artistId: next.artistId,
              artistName: next.artist,
              songCount: next.songCount,
              duration: next.duration,
              coverArt: next.coverArt,
            );
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
      'failures=${metrics.apiFailures} '
      'endpointRequests=${_formatEndpointCounts(metrics.apiRequestsByEndpoint)} '
      'metadataChanged=${metrics.metadataChanged} '
      'skippedReason=${metrics.skippedReason ?? 'none'} '
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
    final pendingHydrationSet = pendingHydrationAlbumIds.toSet();

    return albums
        .map(
          (row) => AlbumsTableCompanion.insert(
            id: row.id,
            name: row.name,
            artistId: Value(row.artistId),
            artistName: Value(row.artist),
            artists: Value(row.artists),
            songCount: Value(row.songCount),
            duration: Value(row.duration),
            year: Value(row.year),
            coverArt: Value(row.coverArt),
            songsHydrated: Value(!pendingHydrationSet.contains(row.id)),
            starred: Value(row.starred),
            userRating: Value(row.userRating),
            playCount: Value(row.playCount),
            serverCreatedAt: Value(row.created),
            releaseMbid: Value(row.musicBrainzId),
            recentlyAddedRank: newestRanks.containsKey(row.id)
                ? Value(newestRanks[row.id])
                : const Value.absent(),
            isExternal: Value(
              isExternalCatalogSource(
                id: row.id,
                apiIsExternal:
                    row.isExternal ??
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
    return songs
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
            artistName: Value(row.artist),
            albumName: Value(row.album),
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
            recordingMbid: Value(row.musicBrainzId),
            userRating: Value(row.userRating),
            playCount: Value(row.playCount),
            createdAt: Value(row.created),
            isExternal: Value(
              isExternalCatalogSource(
                id: row.id,
                apiIsExternal:
                    row.isExternal ??
                    (inheritExternalWhenMissing ? true : null),
              ),
            ),
            replayGainTrackGain: Value(row.replayGain?.trackGain),
            replayGainAlbumGain: Value(row.replayGain?.albumGain),
            replayGainTrackPeak: Value(row.replayGain?.trackPeak),
            replayGainAlbumPeak: Value(row.replayGain?.albumPeak),
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
            readOnly: Value(playlist.readOnly),
            coverArt: Value(playlist.coverArt),
            comment: Value(playlist.comment),
          ),
        )
        .toList(growable: false);
  }
}

Stream<List<T>> _keysetPages<T>({
  required Future<List<T>> Function(String afterId) fetch,
  required String Function(T row) id,
}) async* {
  var afterId = '';
  while (true) {
    final page = await fetch(afterId);
    if (page.isEmpty) return;
    afterId = id(page.last);
    yield page;
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
  await Future.wait(List<Future<void>>.generate(workerCount, (_) => worker()));

  return result.cast<R>();
}

class _SyncRunMetrics {
  SongIdentityReconciliationSession? identitySession;
  static const _maxFailureDiagnostics = 12;

  int apiRequests = 0;
  int apiFailures = 0;
  int dbWriteBatches = 0;
  int hardAlbumFailures = 0;
  int canonicalizedSongCount = 0;
  int ambiguousMatchCount = 0;
  bool metadataChanged = false;
  bool starredSynchronized = false;
  bool playlistHeadersSynchronized = false;
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

  void recordApiAttempt({required Duration elapsed, String? endpoint}) {
    apiRequests++;
    if (endpoint != null && endpoint.isNotEmpty) {
      apiRequestsByEndpoint[endpoint] =
          (apiRequestsByEndpoint[endpoint] ?? 0) + 1;
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
  new({required int initial, required int min, required int max})
    : _min = min < 1 ? 1 : min,
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
    required bool hadTransientPressure,
  }) {
    if (hadTransientPressure) {
      _decrease(by: 2);
      return;
    }
    // Request latency alone is not congestion. Reducing parallelism on a
    // healthy but high-latency server turns a large repair into a serial
    // getAlbum crawl. Back off by two workers after transient album failures
    // or transport retries; otherwise probe toward the bounded limit.
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
