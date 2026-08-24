import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';

import '../../../../helpers/test_database.dart';

void main() {
  late NavisDatabase database;
  late SongIdentityReconciler reconciler;

  setUp(() {
    database = createTestDatabase();
    reconciler = SongIdentityReconciler(database.songIdentityDao);
  });

  tearDown(() async {
    await database.close();
  });

  test('matches an identical provisional ID immediately', () {
    final canonical = _song(id: 'same', provisional: false);
    final result = reconciler.matchCanonicalSong(
      canonicalSong: canonical,
      provisionalSongs: <SongsTableData>[
        _song(id: 'same', provisional: true),
      ],
    );

    expect(result, isA<SongIdentityMatched>());
    expect(
      (result as SongIdentityMatched).reason,
      SongIdentityMatchReason.sameId,
    );
  }, skip: !sqliteAvailable);

  test('matches one unique exact recording MBID', () {
    final result = reconciler.matchCanonicalSong(
      canonicalSong: _song(
        id: 'canonical',
        provisional: false,
        recordingMbid: 'ABC-123',
      ),
      provisionalSongs: <SongsTableData>[
        _song(
          id: 'remote',
          provisional: true,
          recordingMbid: 'abc-123',
        ),
        _song(
          id: 'other',
          provisional: true,
          recordingMbid: 'different',
        ),
      ],
    );

    expect(result, isA<SongIdentityMatched>());
    expect(
      (result as SongIdentityMatched).reason,
      SongIdentityMatchReason.recordingMbid,
    );
    expect(result.provisionalSong.id, 'remote');
  }, skip: !sqliteAvailable);

  test(
    'strict metadata matching requires duration and compatible positions',
    () {
      final canonical = _song(
        id: 'canonical',
        provisional: false,
        title: 'Song!',
        artist: 'The Artist',
        album: 'The Album',
        duration: 201,
        track: 2,
        disc: 1,
      );
      final result = reconciler.matchCanonicalSong(
        canonicalSong: canonical,
        provisionalSongs: <SongsTableData>[
          _song(
            id: 'remote',
            provisional: true,
            title: 'song',
            artist: 'the artist',
            album: 'the album',
            duration: 203,
            track: 2,
            disc: 1,
          ),
        ],
      );

      expect(result, isA<SongIdentityMatched>());
      expect(
        (result as SongIdentityMatched).reason,
        SongIdentityMatchReason.exactMetadata,
      );

      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: canonical.copyWith(title: 'Song (Live)'),
          provisionalSongs: <SongsTableData>[
            _song(
              id: 'different-version',
              provisional: true,
              title: 'Song',
              artist: 'The Artist',
              album: 'The Album',
              duration: 201,
              track: 2,
              disc: 1,
            ),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );

      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: canonical,
          provisionalSongs: <SongsTableData>[
            _song(
              id: 'missing-duration',
              provisional: true,
              title: canonical.title,
              artist: canonical.artistName!,
              album: canonical.albumName!,
              track: 2,
              disc: 1,
            ),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );
    },
    skip: !sqliteAvailable,
  );

  test('retains ambiguous exact candidates', () {
    final canonical = _song(id: 'canonical', provisional: false);
    final result = reconciler.matchCanonicalSong(
      canonicalSong: canonical,
      provisionalSongs: <SongsTableData>[
        _song(id: 'remote-a', provisional: true),
        _song(id: 'remote-b', provisional: true),
      ],
    );

    expect(result, isA<SongIdentityAmbiguous>());
    expect((result as SongIdentityAmbiguous).candidateCount, 2);
  }, skip: !sqliteAvailable);
}

SongsTableData _song({
  required String id,
  required bool provisional,
  String title = 'Track',
  String artist = 'Artist',
  String album = 'Album',
  int? duration = 180,
  int? track = 1,
  int? disc = 1,
  String? recordingMbid,
}) {
  return SongsTableData(
    id: id,
    title: title,
    artistName: artist,
    albumName: album,
    duration: duration,
    track: track,
    discNumber: disc,
    recordingMbid: recordingMbid,
    isProvisional: provisional,
    isExternal: false,
  );
}
