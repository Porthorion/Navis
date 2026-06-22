import 'package:navis/src/api/models/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/group_listening/data/group_listening_track_resolution_cache.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_match_scorer.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_resolution_service.dart';

void main() {
  group('GroupListeningTrackResolutionService', () {
    test('returns library id directly for server-addressable entries', () async {
      final service = GroupListeningTrackResolutionService(api: null);
      final result = await service.resolveEntry(
        entry: GroupListeningQueueEntry(
          queueEntryId: 'q1',
          songId: 'song-123',
          addedByMemberId: 'member',
          addedAt: DateTime.utc(2026),
          playability: GroupListeningPlayability.serverAddressable,
        ),
      );
      expect(result, isA<GroupListeningTrackResolved>());
      expect((result as GroupListeningTrackResolved).songId, 'song-123');
    });

    test('never returns remote fallback ids for unresolved entries', () async {
      final service = GroupListeningTrackResolutionService(api: null);
      final result = await service.resolveEntry(
        entry: GroupListeningQueueEntry(
          queueEntryId: 'q1',
          songId: 'remote-abc',
          addedByMemberId: 'member',
          addedAt: DateTime.utc(2026),
          playability: GroupListeningPlayability.requiresResolution,
          trackRef: const GroupListeningTrackRef(
            kind: GroupListeningTrackRefKind.searchFingerprint,
            searchFingerprint: GroupListeningSearchFingerprint(
              title: 'Unknown',
              artist: 'Artist',
              durationSeconds: 200,
            ),
          ),
        ),
      );
      expect(result, isA<GroupListeningTrackUnavailable>());
    });

    test('uses cache after first resolution', () async {
      final cache = GroupListeningTrackResolutionCache();
      cache.write(
        'library:song-9',
        const GroupListeningTrackResolutionCacheEntry(
          status: GroupListeningTrackResolutionStatus.resolved,
          songId: 'song-9',
          confidence: 1,
        ),
      );
      final service = GroupListeningTrackResolutionService(
        api: null,
        cache: cache,
      );
      final result = await service.resolveEntry(
        entry: GroupListeningQueueEntry(
          queueEntryId: 'q1',
          songId: 'remote-x',
          addedByMemberId: 'member',
          addedAt: DateTime.utc(2026),
          trackRef: const GroupListeningTrackRef(
            kind: GroupListeningTrackRefKind.libraryId,
            librarySongId: 'song-9',
          ),
        ),
      );
      expect((result as GroupListeningTrackResolved).songId, 'song-9');
    });
  });

  group('GroupListeningTrackMatchScorer', () {
    test('prefers exact title and artist matches', () {
      const scorer = GroupListeningTrackMatchScorer();
      final score = scorer.scoreCandidate(
        fingerprint: const GroupListeningSearchFingerprint(
          title: 'Hello',
          artist: 'World',
          durationSeconds: 200,
        ),
        candidate: Song(
          id: 'song-1',
          title: 'Hello',
          artist: 'World',
          duration: 200,
        ),
      );
      expect(score, greaterThan(0.9));
    });
  });
}
