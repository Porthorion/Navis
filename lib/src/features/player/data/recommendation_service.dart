import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

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
  const RecommendationBatch({
    required this.songs,
    required this.source,
    this.issue = RecommendationIssue.none,
  });

  final List<Song> songs;
  final RecommendationSource source;
  final RecommendationIssue issue;
}

class RadioFilters {
  const RadioFilters({this.likedOnly = false, this.downloadedOnly = false});

  final bool likedOnly;
  final bool downloadedOnly;
}

class RecommendationService {
  RecommendationService(this._ref, {Random? random})
    : _random = random ?? Random();

  final Ref _ref;
  final Random _random;

  Future<List<SongsTableData>> eligibleLibrary(RadioFilters filters) async {
    final db = _ref.read(navisDatabaseProvider);
    final catalog = await db.libraryDao.getAllSongs();
    final offline = _ref.read(networkTypeProvider) == NetworkType.offline;
    final cache = {
      for (final entry in await db.cacheDao.getCachedTracks())
        entry.songId: entry,
    };
    final localOnly = await db.libraryDao.getSongsByIds(cache.keys);
    final all = <String, SongsTableData>{
      for (final song in catalog) song.id: song,
      for (final song in localOnly) song.id: song,
    }.values;
    final saf = const AndroidSafStorage();
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
            : await File(local.filePath).exists();
        if (!exists) continue;
      }
      eligible.add(song);
    }
    return eligible;
  }

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
    final collected = <Song>[];
    var source = RecommendationSource.server;
    var issue = RecommendationIssue.empty;
    if (collected.length < count) {
      try {
        final generic = await api.getSimilarSongs2(
          seedId,
          count: count,
          cancelToken: cancelToken,
        );
        final before = collected.length;
        _addEligible(collected, generic, null, seedId, count);
        if (before == 0 && collected.isNotEmpty)
          source = RecommendationSource.server;
        if (collected.isNotEmpty) issue = RecommendationIssue.none;
      } on SubsonicNotFoundException {
        try {
          final legacy = await api.getLegacySimilarSongs(
            seedId,
            count: count,
            cancelToken: cancelToken,
          );
          final before = collected.length;
          _addEligible(collected, legacy, null, seedId, count);
          if (before == 0 && collected.isNotEmpty) {
            source = RecommendationSource.server;
          }
          if (collected.isNotEmpty) issue = RecommendationIssue.none;
        } on SubsonicNotFoundException {
          try {
            final navidrome = await api.getInstantMix(
              seedId,
              count: count,
              cancelToken: cancelToken,
            );
            _addEligible(collected, navidrome, null, seedId, count);
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

  Future<RecommendationBatch> sameVibes(
    Song seed, {
    int count = 5,
    CancelToken? cancelToken,
  }) async {
    final eligible = await eligibleLibrary(const RadioFilters());
    final matched = await _lastFmMatches(seed, eligible, count: count);
    final collected = <Song>[...matched.songs];
    if (collected.length < count &&
        _ref.read(networkTypeProvider) != NetworkType.offline) {
      final fallback = await serverMix(
        seed.id,
        count: count,
        cancelToken: cancelToken,
      );
      _addEligible(
        collected,
        fallback.songs,
        eligible.map((song) => song.id).toSet(),
        seed.id,
        count,
      );
      if (collected.isNotEmpty) {
        return RecommendationBatch(
          songs: collected,
          source: matched.songs.isNotEmpty
              ? RecommendationSource.lastFm
              : fallback.source,
        );
      }
      return fallback;
    }
    return matched;
  }

  Future<RecommendationBatch> personalRadio(
    RadioFilters filters, {
    required Set<String> excludedIds,
    int count = 10,
    CancelToken? cancelToken,
  }) async {
    final eligible = await eligibleLibrary(filters);
    final hardExcluded = <String>{...excludedIds};
    final hardRecordings = eligible
        .where((song) => hardExcluded.contains(song.id))
        .map(_recordingRow)
        .toSet();
    final history = await _ref
        .read(navisDatabaseProvider)
        .historyDao
        .watchPlayHistory(limit: 200)
        .first;
    excludedIds = <String>{
      ...excludedIds,
      ...history.map((play) => play.songId),
    };
    final excludedRecordings = eligible
        .where((song) => excludedIds.contains(song.id))
        .map(_recordingRow)
        .toSet();
    var pool = eligible
        .where(
          (song) =>
              !excludedIds.contains(song.id) &&
              !excludedRecordings.contains(_recordingRow(song)),
        )
        .toList();
    if (pool.isEmpty) {
      // In a small library every recording may be in recent history. Keep
      // session and queue exclusions while allowing older favorites again.
      pool = eligible
          .where(
            (song) =>
                !hardExcluded.contains(song.id) &&
                !hardRecordings.contains(_recordingRow(song)),
          )
          .toList();
      excludedIds = hardExcluded;
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
      excludedIds: excludedIds,
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
  }) async {
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
    for (final song in eligible) {
      byIdentity
          .putIfAbsent(
            _identity(song.artistName ?? '', song.title),
            () => <SongsTableData>[],
          )
          .add(song);
    }
    final matches = <Song>[];
    for (final recommendation in result.tracks.take(10)) {
      final editions =
          byIdentity[_identity(
            recommendation.artist,
            recommendation.title,
          )];
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
    int limit,
  ) {
    final existing = target.map((song) => song.id).toSet()..add(seedId);
    for (final song in candidates) {
      if (target.length >= limit) break;
      if ((eligibleIds == null || eligibleIds.contains(song.id)) &&
          existing.add(song.id)) {
        target.add(song);
      }
    }
  }

  static String _identity(String artist, String title) =>
      '${artist.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}:'
      '${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}';

  static String _recordingRow(SongsTableData song) {
    final mbid = song.recordingMbid?.trim().toLowerCase();
    return mbid != null && mbid.isNotEmpty
        ? 'mbid:$mbid'
        : _identity(song.artistName ?? '', song.title);
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
  String recording(Song song) {
    final mbid = song.musicBrainzId?.trim().toLowerCase();
    return mbid != null && mbid.isNotEmpty
        ? 'mbid:$mbid'
        : RecommendationService._identity(song.artist ?? '', song.title);
  }

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

final recommendationServiceProvider = Provider<RecommendationService>(
  (ref) => RecommendationService(ref),
);
