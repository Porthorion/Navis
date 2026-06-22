import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/group_listening/data/group_listening_track_resolution_cache.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_match_scorer.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

enum GroupListeningTrackResolutionReadiness {
  ready,
  resolving,
  unavailable,
}

sealed class GroupListeningTrackResolutionResult {
  const GroupListeningTrackResolutionResult();
}

class GroupListeningTrackResolved extends GroupListeningTrackResolutionResult {
  const GroupListeningTrackResolved({
    required this.songId,
    required this.confidence,
  });

  final String songId;
  final double confidence;
}

class GroupListeningTrackUnavailable
    extends GroupListeningTrackResolutionResult {
  const GroupListeningTrackUnavailable({required this.reason});

  final String reason;
}

final groupListeningTrackResolutionServiceProvider =
    Provider<GroupListeningTrackResolutionService>((ref) {
      final api = ref.watch(subsonicApiProvider);
      return GroupListeningTrackResolutionService(api: api);
    });

/// Resolves portable queue entries to local playable song IDs.
class GroupListeningTrackResolutionService {
  GroupListeningTrackResolutionService({
    required SubsonicApiClient? api,
    GroupListeningTrackMatchScorer? scorer,
    GroupListeningTrackResolutionCache? cache,
  }) : _api = api,
       _scorer = scorer ?? const GroupListeningTrackMatchScorer(),
       _cache = cache ?? GroupListeningTrackResolutionCache();

  final SubsonicApiClient? _api;
  final GroupListeningTrackMatchScorer _scorer;
  final GroupListeningTrackResolutionCache _cache;

  static const int _maxSearchQueries = 2;
  static const int _searchSongCount = 8;

  final Map<String, GroupListeningTrackResolutionReadiness> _readiness =
      <String, GroupListeningTrackResolutionReadiness>{};

  GroupListeningTrackResolutionReadiness readinessFor(String queueEntryId) =>
      _readiness[queueEntryId] ?? GroupListeningTrackResolutionReadiness.ready;

  void setReadiness(
    String queueEntryId,
    GroupListeningTrackResolutionReadiness status,
  ) {
    _readiness[queueEntryId] = status;
  }

  String cacheKeyFor(GroupListeningTrackRef trackRef) {
    return switch (trackRef.kind) {
      GroupListeningTrackRefKind.libraryId =>
        'library:${trackRef.librarySongId ?? ''}',
      GroupListeningTrackRefKind.mbid => 'mbid:${trackRef.mbid ?? ''}',
      GroupListeningTrackRefKind.searchFingerprint =>
        'fp:${trackRef.searchFingerprint?.title ?? ''}:'
            '${trackRef.searchFingerprint?.artist ?? ''}:'
            '${trackRef.searchFingerprint?.durationSeconds ?? 0}',
    };
  }

  Future<GroupListeningTrackResolutionResult> resolveEntry({
    required GroupListeningQueueEntry entry,
  }) async {
    if (isServerAddressableSongId(entry.songId) &&
        entry.playability == GroupListeningPlayability.serverAddressable) {
      return GroupListeningTrackResolved(songId: entry.songId, confidence: 1);
    }

    final trackRef = entry.trackRef;
    if (trackRef == null) {
      if (isServerAddressableSongId(entry.songId)) {
        return GroupListeningTrackResolved(
          songId: entry.songId,
          confidence: 1,
        );
      }
      return const GroupListeningTrackUnavailable(
        reason: 'missing_track_ref',
      );
    }

    if (trackRef.kind == GroupListeningTrackRefKind.libraryId) {
      final libraryId = trackRef.librarySongId;
      if (libraryId != null &&
          libraryId.isNotEmpty &&
          isServerAddressableSongId(libraryId)) {
        return GroupListeningTrackResolved(songId: libraryId, confidence: 1);
      }
    }

    final cacheKey = cacheKeyFor(trackRef);
    final cached = _cache.read(cacheKey);
    if (cached != null) {
      return switch (cached.status) {
        GroupListeningTrackResolutionStatus.resolved =>
          GroupListeningTrackResolved(
            songId: cached.songId!,
            confidence: cached.confidence ?? 1,
          ),
        GroupListeningTrackResolutionStatus.unavailable =>
          GroupListeningTrackUnavailable(
            reason: cached.reason ?? 'unavailable',
          ),
      };
    }

    final api = _api;
    if (api == null) {
      return const GroupListeningTrackUnavailable(reason: 'api_unavailable');
    }

    setReadiness(
      entry.queueEntryId,
      GroupListeningTrackResolutionReadiness.resolving,
    );

    final resolved = switch (trackRef.kind) {
      GroupListeningTrackRefKind.libraryId => null,
      GroupListeningTrackRefKind.mbid => await _resolveByMbid(api, trackRef),
      GroupListeningTrackRefKind.searchFingerprint =>
        await _resolveByFingerprint(
          api,
          trackRef,
          entry,
        ),
    };

    if (resolved == null) {
      setReadiness(
        entry.queueEntryId,
        GroupListeningTrackResolutionReadiness.unavailable,
      );
      _cache.write(
        cacheKey,
        const GroupListeningTrackResolutionCacheEntry(
          status: GroupListeningTrackResolutionStatus.unavailable,
          reason: 'not_found',
        ),
      );
      AppLogger.debug(
        'Group listening: resolution_fail entry=${entry.queueEntryId}',
      );
      return const GroupListeningTrackUnavailable(reason: 'not_found');
    }

    setReadiness(
      entry.queueEntryId,
      GroupListeningTrackResolutionReadiness.ready,
    );
    _cache.write(
      cacheKey,
      GroupListeningTrackResolutionCacheEntry(
        status: GroupListeningTrackResolutionStatus.resolved,
        songId: resolved.songId,
        confidence: resolved.confidence,
      ),
    );
    return resolved;
  }

  Future<void> prefetchEntries(List<GroupListeningQueueEntry> entries) async {
    for (final entry in entries) {
      if (readinessFor(entry.queueEntryId) ==
          GroupListeningTrackResolutionReadiness.resolving) {
        continue;
      }
      unawaited(resolveEntry(entry: entry));
    }
  }

  Future<List<String>> resolveQueueSongIds({
    required List<GroupListeningQueueEntry> entries,
  }) async {
    final resolvedIds = <String>[];
    for (final entry in entries) {
      final result = await resolveEntry(entry: entry);
      resolvedIds.add(switch (result) {
        GroupListeningTrackResolved(:final songId) => songId,
        GroupListeningTrackUnavailable() => '',
      });
    }
    return List<String>.unmodifiable(resolvedIds);
  }

  Future<GroupListeningTrackResolved?> _resolveByMbid(
    SubsonicApiClient api,
    GroupListeningTrackRef trackRef,
  ) async {
    final mbid = trackRef.mbid?.trim();
    if (mbid == null || mbid.isEmpty) {
      return null;
    }
    try {
      final search = await api.search3(
        query: mbid,
        artistCount: 0,
        albumCount: 0,
        songCount: _searchSongCount,
      );
      for (final song in search.songs) {
        if (song.id.trim().toLowerCase().contains(mbid.toLowerCase()) &&
            isServerAddressableSongId(song.id)) {
          return GroupListeningTrackResolved(songId: song.id, confidence: 0.9);
        }
      }
    } on Object catch (error) {
      AppLogger.debug('Group listening MBID resolve failed: $error');
    }
    return null;
  }

  Future<GroupListeningTrackResolved?> _resolveByFingerprint(
    SubsonicApiClient api,
    GroupListeningTrackRef trackRef,
    GroupListeningQueueEntry entry,
  ) async {
    final fingerprint =
        trackRef.searchFingerprint ??
        GroupListeningSearchFingerprint(
          title: entry.title ?? '',
          artist: entry.artist ?? '',
          album: entry.album,
          durationSeconds: entry.durationSeconds ?? 0,
        );
    final queries = _mappingQueriesFor(fingerprint).take(_maxSearchQueries);
    for (final query in queries) {
      try {
        final search = await api.search3(
          query: query,
          artistCount: 0,
          albumCount: 0,
          songCount: _searchSongCount,
        );
        final candidate = _scorer.pickBestCandidate(
          fingerprint: fingerprint,
          songs: search.songs,
        );
        if (candidate != null) {
          return GroupListeningTrackResolved(
            songId: candidate.id,
            confidence: _scorer.scoreCandidate(
              fingerprint: fingerprint,
              candidate: candidate,
            ),
          );
        }
      } on Object catch (error) {
        AppLogger.debug('Group listening search3 resolve failed: $error');
      }
    }
    return null;
  }

  List<String> _mappingQueriesFor(GroupListeningSearchFingerprint fingerprint) {
    final artist = fingerprint.artist.trim();
    final title = fingerprint.title.trim();
    final queries = <String>[
      '$artist $title'.trim(),
      '$title $artist'.trim(),
      title,
      artist,
    ];
    final seen = <String>{};
    return queries
        .where((query) => query.isNotEmpty && seen.add(query.toLowerCase()))
        .toList(growable: false);
  }
}
