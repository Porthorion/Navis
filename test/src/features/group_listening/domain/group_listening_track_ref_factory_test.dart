import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_session_models.dart';
import 'package:navis/src/features/group_listening/domain/group_listening_track_ref_factory.dart';

void main() {
  group('group_listening_track_ref_factory', () {
    test('buildTrackRefForSong uses library id for server-addressable songs', () {
      final ref = buildTrackRefForSong(
        const Song(id: 'song-1', title: 'Track', artist: 'Artist'),
      );
      expect(ref.kind, GroupListeningTrackRefKind.libraryId);
      expect(ref.librarySongId, 'song-1');
    });

    test('buildTrackRefForSong uses search fingerprint for remote ids', () {
      final ref = buildTrackRefForSong(
        const Song(
          id: 'remote-abc',
          title: 'Remote Track',
          artist: 'Remote Artist',
          album: 'Album',
          duration: 240,
        ),
      );
      expect(ref.kind, GroupListeningTrackRefKind.searchFingerprint);
      expect(ref.searchFingerprint?.title, 'Remote Track');
      expect(ref.searchFingerprint?.artist, 'Remote Artist');
      expect(ref.searchFingerprint?.album, 'Album');
      expect(ref.searchFingerprint?.durationSeconds, 240);
    });

    test('playabilityForSongId marks remote ids as requires resolution', () {
      expect(
        playabilityForSongId('remote-abc'),
        GroupListeningPlayability.requiresResolution,
      );
      expect(
        playabilityForSongId('song-1'),
        GroupListeningPlayability.serverAddressable,
      );
    });
  });
}
