import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart'
    show kLocalTrackMatcherSnapshotYieldChunkSize;
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
import 'package:navis/src/utils/song_id_utils.dart';

enum RecommendationSource { server, instantMix, lastFm, localTaste, shuffle }

enum RecommendationIssue {
  none,
  unsupported,
  empty,
  invalidKey,
  rateLimited,
  networkFailure,
}

class RecommendationBatch {
  const new({
    required this.songs,
    required this.source,
    this.issue = RecommendationIssue.none,
  });

  final List<Song> songs;
  final RecommendationSource source;
  final RecommendationIssue issue;
}

class RadioFilters {
  const new({this.likedOnly = false, this.downloadedOnly = false});

  final bool likedOnly;
  final bool downloadedOnly;
}

class RecommendationService {
  new(
    this._ref, {
    Random? random,
    this._eligibleLibraryMaxAge = const Duration(minutes: 2),
  }) : _random = random ?? Random() {
    _ref.onDispose(() => _eligibleLibraryRelease?.cancel());
  }

  final Ref _ref;
  final Random _random;

  /// Radio refills ask for the eligible library every few songs; reading the
  /// whole catalog and checking local files each time is the expensive part.
  /// The result is reused until songs or cached tracks change, the network
  /// or filters differ, or it is older than [_eligibleLibraryMaxAge].
  final Duration _eligibleLibraryMaxAge;
  Timer? _eligibleLibraryRelease;

  @visibleForTesting
  bool get debugHasEligibleLibrary => _eligibleLibraryCache != null;

  ({
    Object key,
    int revision,
    DateTime at,
    List<SongsTableData> songs,
    _IdentityCache identities,
  })?
  _eligibleLibraryCache;
  int _libraryRevision = 0;
  bool _watchingLibrary = false;

  Future<List<SongsTableData>> eligibleLibrary(RadioFilters filters) async {
    final db = _ref.read(navisDatabaseProvider);
    if (!_watchingLibrary) {
      _watchingLibrary = true;
      final subscription = db
          .tableUpdates(
            TableUpdateQuery.onAllTables([db.songsTable, db.cachedTracksTable]),
          )
          .listen((_) => _libraryRevision++);
      _ref.onDispose(subscription.cancel);
    }
    final offline = _ref.read(networkTypeProvider) == NetworkType.offline;
    final key = (filters.likedOnly, filters.downloadedOnly, offline);
    final cached = _eligibleLibraryCache;
    if (cached != null &&
        cached.key == key &&
        cached.revision == _libraryRevision &&
        DateTime.now().difference(cached.at) < _eligibleLibraryMaxAge) {
      return List<SongsTableData>.of(cached.songs);
    }
    final revision = _libraryRevision;
    final catalog = await db.libraryDao.getAllSongs();
    final cache = {
      for (final entry in await db.cacheDao.getCachedTracks())
        entry.songId: entry,
    };
    final localOnly = await db.libraryDao.getSongsByIds(cache.keys);
    final all = <String, SongsTableData>{
      for (final song in catalog) song.id: song,
      for (final song in localOnly) song.id: song,
    }.values;
    const saf = AndroidSafStorage();
    final eligible = <SongsTableData>[];
    for (final song in all) {
      if (song.isExternal || song.isProvisional) continue;
      if (filters.likedOnly && song.starred == null) continue;
      final local = cache[song.id];
      final needsLocal =
          offline || filters.downloadedOnly || song.serverDeletedAt != null;
      if (needsLocal) {
        if (local == null || local.downloadStatus != DownloadStatus.complete) {
          continue;
        }
        if (filters.downloadedOnly && local.cacheType != CacheType.permanent) {
          continue;
        }
        if (song.serverDeletedAt != null &&
            local.cacheType != CacheType.permanent) {
          continue;
        }
        final exists =
            local.storageKind == 'androidSaf' ||
                local.filePath.startsWith('content://')
            ? await saf.exists(local.filePath)
            // Keep metadata access asynchronous so storage latency cannot stall UI.
            // ignore: avoid_slow_async_io
            : await File(local.filePath).exists();
        if (!exists) continue;
      }
      eligible.add(song);
    }
    // Identities are normalised once per pool, in chunks, so refills reuse
    // them and building them never blocks the UI isolate in one pass.
    final identities = _IdentityCache();
    for (var index = 0; index < eligible.length; index++) {
      _recordingRow(eligible[index], identities);
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    _eligibleLibraryCache = (
      key: key,
      revision: revision,
      at: DateTime.now(),
      songs: List<SongsTableData>.unmodifiable(eligible),
      identities: identities,
    );
    // The pool holds every eligible song; drop it once it can no longer be
    // reused instead of keeping it for the app's lifetime.
    _eligibleLibraryRelease?.cancel();
    _eligibleLibraryRelease = Timer(_eligibleLibraryMaxAge, () {
      _eligibleLibraryCache = null;
    });
    return eligible;
  }

  /// The identity cache built with the current pool for [filters].
  Future<_IdentityCache> _poolIdentities(RadioFilters filters) async {
    await eligibleLibrary(filters);
    return _eligibleLibraryCache?.identities ?? _IdentityCache();
  }

  @visibleForTesting
  Future<String> debugRecordingIdentity(
    RadioFilters filters,
    String songId,
  ) async {
    final pool = await eligibleLibrary(filters);
    final identities = await _poolIdentities(filters);
    return _recordingRow(
      pool.firstWhere((song) => song.id == songId),
      identities,
    );
  }

  @visibleForTesting
  static String debugIdentity(String artist, String title) =>
      _identity(artist, title);

  Future<RecommendationBatch> serverMix(
    String seedId, {
    int count = 10,
    CancelToken? cancelToken,
  }) async {
    final api = _ref.read(subsonicApiProvider);
    if (api == null) {
      return const RecommendationBatch(
        songs: <Song>[],
        source: RecommendationSource.server,
        issue: RecommendationIssue.networkFailure,
      );
    }
    // The server's similarity endpoints know only its own ids. A remote song
    // (an Octo-Fiesta `ext-` id) mixes from the library copy getSong maps it
    // to, when the server has one.
    final mixSeedId = isServerAddressableSongId(seedId)
        ? seedId
        : await libraryCopyId(api, seedId, cancelToken: cancelToken) ?? seedId;
    final collected = <Song>[];
    var source = RecommendationSource.server;
    var issue = RecommendationIssue.empty;
    if (collected.length < count) {
      try {
        final generic = await api.getSimilarSongs2(
          mixSeedId,
          count: count,
          cancelToken: cancelToken,
        );
        final before = collected.length;
        _addEligible(
          collected,
          generic,
          null,
          mixSeedId,
          count,
          alsoExcludedId: seedId,
        );
        if (before == 0 && collected.isNotEmpty) {
          source = RecommendationSource.server;
        }
        if (collected.isNotEmpty) issue = RecommendationIssue.none;
      } on SubsonicNotFoundException {
        try {
          final legacy = await api.getLegacySimilarSongs(
            mixSeedId,
            count: count,
            cancelToken: cancelToken,
          );
          final before = collected.length;
          _addEligible(
            collected,
            legacy,
            null,
            mixSeedId,
            count,
            alsoExcludedId: seedId,
          );
          if (before == 0 && collected.isNotEmpty) {
            source = RecommendationSource.server;
          }
          if (collected.isNotEmpty) issue = RecommendationIssue.none;
        } on SubsonicNotFoundException {
          try {
            final navidrome = await api.getInstantMix(
              mixSeedId,
              count: count,
              cancelToken: cancelToken,
            );
            _addEligible(
              collected,
              navidrome,
              null,
              mixSeedId,
              count,
              alsoExcludedId: seedId,
            );
            if (collected.isNotEmpty) {
              source = RecommendationSource.instantMix;
              issue = RecommendationIssue.none;
            }
          } on SubsonicNotFoundException {
            if (collected.isEmpty) issue = RecommendationIssue.unsupported;
          }
        }
      } on SubsonicConnectionException {
        if (collected.isEmpty) issue = RecommendationIssue.networkFailure;
      }
    }
    return RecommendationBatch(
      songs: collected,
      source: source,
      issue: collected.isEmpty ? issue : RecommendationIssue.none,
    );
  }

  /// The server's library copy of the remote song [seedId], or null when
  /// getSong answers with the remote song itself or fails.
  Future<String?> libraryCopyId(
    SubsonicApiClient api,
    String seedId, {
    CancelToken? cancelToken,
  }) async {
    try {
      final song = await api.getSong(seedId, cancelToken: cancelToken);
      final id = song.id.trim();
      return id != seedId && isServerAddressableSongId(id) ? id : null;
    } on SubsonicException {
      return null;
    }
  }

  Future<RecommendationBatch> personalRadio(
    RadioFilters filters, {
    required Set<String> excludedIds,
    int count = 10,
    CancelToken? cancelToken,
  }) async {
    var resolvedExcludedIds = excludedIds;

    final eligible = await eligibleLibrary(filters);
    // Identities were computed once with the cached pool.
    final identities = await _poolIdentities(filters);
    String recordingRow(SongsTableData song) => _recordingRow(song, identities);
    final hardExcluded = <String>{...excludedIds};
    final hardRecordings = eligible
        .where((song) => hardExcluded.contains(song.id))
        .map(recordingRow)
        .toSet();
    final history = await _ref
        .read(navisDatabaseProvider)
        .historyDao
        .watchPlayHistory(limit: 200)
        .first;
    resolvedExcludedIds = <String>{
      ...excludedIds,
      ...history.map((play) => play.songId),
    };
    final excludedRecordings = eligible
        .where((song) => resolvedExcludedIds.contains(song.id))
        .map(recordingRow)
        .toSet();
    var pool = eligible
        .where(
          (song) =>
              !resolvedExcludedIds.contains(song.id) &&
              !excludedRecordings.contains(recordingRow(song)),
        )
        .toList();
    if (pool.isEmpty) {
      // In a small library every recording may be in recent history. Keep
      // session and queue exclusions while allowing older favorites again.
      pool = eligible
          .where(
            (song) =>
                !hardExcluded.contains(song.id) &&
                !hardRecordings.contains(recordingRow(song)),
          )
          .toList();
      resolvedExcludedIds = hardExcluded;
    }
    if (pool.isEmpty) {
      return const RecommendationBatch(
        songs: <Song>[],
        source: RecommendationSource.shuffle,
        issue: RecommendationIssue.empty,
      );
    }
    final db = _ref.read(navisDatabaseProvider);
    final recent = await db.historyDao
        .watchRecentlyPlayedSongs(limit: 60)
        .first;
    final recentIds = recent.map((song) => song.id).toSet();
    final taste = <SongsTableData>[
      ...eligible.where(
        (song) => song.starred != null && recentIds.contains(song.id),
      ),
      ...eligible.where((song) => song.starred != null),
      ...eligible.where((song) => song.starred != null),
      ...eligible.where((song) => recentIds.contains(song.id)),
    ]..shuffle(_random);
    final liked = pool.where((song) => song.starred != null).toList();
    final anchors = <SongsTableData>[
      ...pool.where(
        (song) => song.starred != null && recentIds.contains(song.id),
      ),
      ...liked,
      ...liked,
      ...pool.where((song) => recentIds.contains(song.id)),
    ];
    anchors.shuffle(_random);
    final seed = taste.isNotEmpty
        ? taste.first
        : pool[_random.nextInt(pool.length)];
    final wantedRelated = (count * 0.7).round();
    final related = <Song>[];
    var source = RecommendationSource.localTaste;
    if (_ref.read(networkTypeProvider) != NetworkType.offline) {
      final server = await serverMix(
        seed.id,
        count: wantedRelated,
        cancelToken: cancelToken,
      );
      final poolIds = pool.map((song) => song.id).toSet();
      related.addAll(server.songs.where((song) => poolIds.contains(song.id)));
      if (related.isNotEmpty) source = server.source;
      if (related.length < wantedRelated) {
        final lastFm = await _lastFmMatches(
          _toSong(seed),
          pool,
          count: wantedRelated - related.length,
          identities: identities,
        );
        _addEligible(
          related,
          lastFm.songs,
          pool.map((song) => song.id).toSet(),
          seed.id,
          wantedRelated,
        );
        if (source == RecommendationSource.localTaste && related.isNotEmpty) {
          source = RecommendationSource.lastFm;
        }
      }
    }
    final chosen = composeRadioBatch(
      related: related,
      familiar: anchors.map(_toSong).toList(),
      shuffle: pool.map(_toSong).toList()..shuffle(_random),
      excludedIds: resolvedExcludedIds,
      count: count,
    );
    return RecommendationBatch(
      songs: chosen,
      source: source == RecommendationSource.localTaste && anchors.isEmpty
          ? RecommendationSource.shuffle
          : source,
      issue: chosen.isEmpty
          ? RecommendationIssue.empty
          : RecommendationIssue.none,
    );
  }

  Future<RecommendationBatch> _lastFmMatches(
    Song seed,
    List<SongsTableData> eligible, {
    required int count,
    _IdentityCache? identities,
  }) async {
    if (!_ref
        .read(integrationPolicyProvider)
        .allows(IntegrationFeature.lastFmRadio)) {
      // Turned off, or no key: the caller falls back to the server.
      return const RecommendationBatch(
        songs: <Song>[],
        source: RecommendationSource.lastFm,
        issue: RecommendationIssue.empty,
      );
    }
    final client = _ref.read(lastFmApiClientProvider);
    if (client == null) {
      return const RecommendationBatch(
        songs: <Song>[],
        source: RecommendationSource.lastFm,
        issue: RecommendationIssue.invalidKey,
      );
    }
    final result = await client.getSimilarTracksResult(
      artist: seed.artist ?? '',
      track: seed.title,
      limit: 20,
    );
    final issue = switch (result.outcome) {
      LastFmFetchOutcome.success => RecommendationIssue.none,
      LastFmFetchOutcome.noResults => RecommendationIssue.empty,
      LastFmFetchOutcome.notConfigured => RecommendationIssue.invalidKey,
      LastFmFetchOutcome.networkError => RecommendationIssue.networkFailure,
      LastFmFetchOutcome.apiError when result.apiErrorCode == 10 =>
        RecommendationIssue.invalidKey,
      LastFmFetchOutcome.apiError when result.statusCode == 429 =>
        RecommendationIssue.rateLimited,
      _ => RecommendationIssue.networkFailure,
    };
    final byIdentity = <String, List<SongsTableData>>{};
    final cache = identities ?? _IdentityCache();
    for (final song in eligible) {
      byIdentity
          .putIfAbsent(cache.ofRow(song), () => <SongsTableData>[])
          .add(song);
    }
    final matches = <Song>[];
    for (final recommendation in result.tracks.take(10)) {
      final editions =
          byIdentity[_identity(recommendation.artist, recommendation.title)];
      if (editions == null) continue;
      final chosen = editions.firstWhere(
        (song) => song.starred != null,
        orElse: () => editions.first,
      );
      if (chosen.id == seed.id || matches.any((song) => song.id == chosen.id)) {
        continue;
      }
      matches.add(_toSong(chosen));
      if (matches.length >= count) break;
    }
    return RecommendationBatch(
      songs: matches,
      source: RecommendationSource.lastFm,
      issue: matches.isEmpty ? issue : RecommendationIssue.none,
    );
  }

  static void _addEligible(
    List<Song> target,
    List<Song> candidates,
    Set<String>? eligibleIds,
    String seedId,
    int limit, {
    String? alsoExcludedId,
  }) {
    final existing = target.map((song) => song.id).toSet()
      ..add(seedId)
      ..addAll(<String>[?alsoExcludedId]);
    for (final song in candidates) {
      if (target.length >= limit) break;
      if ((eligibleIds == null || eligibleIds.contains(song.id)) &&
          existing.add(song.id)) {
        target.add(song);
      }
    }
  }

  /// One recording's artist and title, ignoring case, spacing, punctuation,
  /// diacritics, width and featured credits but keeping edition qualifiers
  /// such as "(Japanese Version)". Letters of every script count.
  static String _identity(String artist, String title) =>
      '${normalizeMetadataKeepingEdition(artist).replaceAll(' ', '')}:'
      '${normalizeMetadataKeepingEdition(title).replaceAll(' ', '')}';

  static String _recordingRow(SongsTableData song, _IdentityCache identities) {
    final mbid = song.recordingMbid?.trim().toLowerCase();
    return mbid != null && mbid.isNotEmpty
        ? 'mbid:$mbid'
        : identities.ofRow(song);
  }

  static Song _toSong(SongsTableData row) => Song(
    id: row.id,
    title: row.title,
    artist: row.artistName,
    album: row.albumName,
    albumId: row.albumId,
    artistId: row.artistId,
    coverArt: row.coverArt,
    starred: row.starred,
    musicBrainzId: row.recordingMbid,
  );
}

/// Interleaves recommendations with familiar anchors, then fills any shortfall
/// from eligible library songs. Identity and artist spacing apply to all three.
List<Song> composeRadioBatch({
  required List<Song> related,
  required List<Song> familiar,
  required List<Song> shuffle,
  required Set<String> excludedIds,
  int count = 10,
}) {
  final result = <Song>[];
  final used = <String>{...excludedIds};
  final usedRecordings = <String>{};
  // Recordings are compared many times per song; compute each once.
  final recordings = <String, String>{};
  String recording(Song song) => recordings.putIfAbsent(song.id, () {
    final mbid = song.musicBrainzId?.trim().toLowerCase();
    return mbid != null && mbid.isNotEmpty
        ? 'mbid:$mbid'
        : RecommendationService._identity(song.artist ?? '', song.title);
  });

  final artistCounts = <String, int>{};
  final sources = <List<Song>>[related, familiar, shuffle];
  for (var index = 0; index < count; index++) {
    final preferred = index % 3 == 2 ? 1 : 0;
    Song? choice;
    for (final sourceIndex in <int>[preferred, 0, 1, 2]) {
      final source = sources[sourceIndex];
      for (final song in source) {
        final artist = (song.artist ?? '').toLowerCase();
        if (used.contains(song.id) ||
            usedRecordings.contains(recording(song)) ||
            (result.isNotEmpty &&
                (result.last.artist ?? '').toLowerCase() == artist)) {
          continue;
        }
        if ((artistCounts[artist] ?? 0) >= 2 && result.length < count - 2) {
          continue;
        }
        choice = song;
        break;
      }
      if (choice != null) break;
    }
    if (choice == null) {
      for (final song in <Song>[...related, ...familiar, ...shuffle]) {
        if (!used.contains(song.id) &&
            !usedRecordings.contains(recording(song))) {
          choice = song;
          break;
        }
      }
    }
    if (choice == null) break;
    result.add(choice);
    used.add(choice.id);
    usedRecordings.add(recording(choice));
    final artist = (choice.artist ?? '').toLowerCase();
    artistCounts[artist] = (artistCounts[artist] ?? 0) + 1;
  }
  return result;
}

/// [RecommendationService._identity] of library rows, computed once per song
/// id for the cached pool.
class _IdentityCache {
  final Map<String, String> _byId = <String, String>{};

  String ofRow(SongsTableData song) => _byId.putIfAbsent(
    song.id,
    () => RecommendationService._identity(song.artistName ?? '', song.title),
  );
}

final recommendationServiceProvider = Provider<RecommendationService>(
  RecommendationService.new,
);
