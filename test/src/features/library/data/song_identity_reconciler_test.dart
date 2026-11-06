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
      provisionalSongs: <SongsTableData>[_song(id: 'same', provisional: true)],
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
        _song(id: 'remote', provisional: true, recordingMbid: 'abc-123'),
        _song(id: 'other', provisional: true, recordingMbid: 'different'),
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

  test('conflicting recording MBIDs prohibit metadata-only matching', () {
    final canonical = _song(
      id: 'canonical',
      provisional: false,
      recordingMbid: 'mbid-a',
    );
    final result = reconciler.matchCanonicalSong(
      canonicalSong: canonical,
      provisionalSongs: <SongsTableData>[
        _song(id: 'remote', provisional: true, recordingMbid: 'mbid-b'),
      ],
    );

    expect(result, isA<SongIdentityUnmatched>());
  }, skip: !sqliteAvailable);

  test('matching does not depend on candidate or canonical page order', () {
    final canonical = _song(
      id: 'canonical-b',
      provisional: false,
      title: 'Song B',
      recordingMbid: 'shared-mbid',
    );
    final candidates = <SongsTableData>[
      _song(
        id: 'remote-b',
        provisional: true,
        title: 'Song B',
        recordingMbid: 'shared-mbid',
      ),
      _song(
        id: 'remote-a',
        provisional: true,
        title: 'Song A',
        recordingMbid: 'other-mbid',
      ),
    ];

    final forward = reconciler.matchCanonicalSong(
      canonicalSong: canonical,
      provisionalSongs: candidates,
    );
    final reversed = reconciler.matchCanonicalSong(
      canonicalSong: canonical,
      provisionalSongs: candidates.reversed.toList(),
    );

    expect((forward as SongIdentityMatched).provisionalSong.id, 'remote-b');
    expect((reversed as SongIdentityMatched).provisionalSong.id, 'remote-b');
  }, skip: !sqliteAvailable);

  test('session captures ambiguity with involved IDs for review', () async {
    final canonical = _song(id: 'canonical', provisional: false, title: 'Twin');
    final session = await reconciler.startSession(
      provisionalSongs: <SongsTableData>[
        _song(id: 'remote-a', provisional: true, title: 'Twin'),
        _song(id: 'remote-b', provisional: true, title: 'Twin'),
      ],
    );
    await session.reconcile(<SongsTableData>[canonical]);

    final summary = session.summary;
    expect(summary.ambiguousMatchCount, 1);
    expect(summary.ambiguousCases.single.canonicalSongId, 'canonical');
    expect(summary.ambiguousCases.single.candidateIds, <String>[
      'remote-a',
      'remote-b',
    ]);
  }, skip: !sqliteAvailable);

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
    final ambiguous = result as SongIdentityAmbiguous;
    expect(ambiguous.candidateCount, 2);
    expect(ambiguous.canonicalSongId, 'canonical');
    expect(ambiguous.candidateIds, ['remote-a', 'remote-b']);
  }, skip: !sqliteAvailable);

  test('canonical rows contending for one recording MBID resolve as ambiguous regardless of arrival order', () async {
    Future<SongIdentityReconciliationSummary> run(
      List<SongsTableData> canonicals,
    ) async {
      final session = await reconciler.startSession(
        provisionalSongs: <SongsTableData>[
          _song(id: 'remote', provisional: true, recordingMbid: 'shared-mbid'),
        ],
      );
      await session.reconcile(canonicals);
      await session.finalize();
      return session.summary;
    }

    final first = _song(
      id: 'canonical-a',
      provisional: false,
      recordingMbid: 'shared-mbid',
    );
    final second = _song(
      id: 'canonical-b',
      provisional: false,
      recordingMbid: 'shared-mbid',
    );

    for (final summary in <SongIdentityReconciliationSummary>[
      await run(<SongsTableData>[first, second]),
      await run(<SongsTableData>[second, first]),
    ]) {
      expect(summary.aliases, isEmpty);
      expect(summary.canonicalizedSongCount, 0);
      expect(summary.ambiguousMatchCount, 2);
      expect(summary.retainedProvisionalCount, 1);
      expect(
        summary.ambiguousCases.map((entry) => entry.canonicalSongId).toSet(),
        <String>{'canonical-a', 'canonical-b'},
      );
      for (final entry in summary.ambiguousCases) {
        expect(entry.candidateIds, <String>['remote']);
      }
    }
  }, skip: !sqliteAvailable);

  test('canonical rows contending for one metadata candidate resolve as ambiguous regardless of arrival order', () async {
    Future<SongIdentityReconciliationSummary> run(
      List<SongsTableData> canonicals,
    ) async {
      final session = await reconciler.startSession(
        provisionalSongs: <SongsTableData>[
          _song(id: 'remote', provisional: true),
        ],
      );
      await session.reconcile(canonicals);
      await session.finalize();
      return session.summary;
    }

    final first = _song(id: 'canonical-a', provisional: false);
    final second = _song(id: 'canonical-b', provisional: false);

    for (final summary in <SongIdentityReconciliationSummary>[
      await run(<SongsTableData>[first, second]),
      await run(<SongsTableData>[second, first]),
    ]) {
      expect(summary.aliases, isEmpty);
      expect(summary.canonicalizedSongCount, 0);
      expect(summary.ambiguousMatchCount, 2);
      expect(summary.retainedProvisionalCount, 1);
      expect(
        summary.ambiguousCases.map((entry) => entry.canonicalSongId).toSet(),
        <String>{'canonical-a', 'canonical-b'},
      );
      for (final entry in summary.ambiguousCases) {
        expect(entry.candidateIds, <String>['remote']);
      }
    }
  }, skip: !sqliteAvailable);

  test(
    'a same-identity claim keeps precedence over a contested MBID claim',
    () async {
      final provisional = _song(
        id: 'shared',
        provisional: true,
        recordingMbid: 'm-x',
      );
      await database.into(database.songsTable).insert(provisional);
      final session = await reconciler.startSession(
        provisionalSongs: <SongsTableData>[provisional],
      );
      // The weaker recording-MBID claim arrives before the same-identity
      // claim; arrival order must not decide the outcome.
      await session.reconcile(<SongsTableData>[
        _song(id: 'other', provisional: false, recordingMbid: 'm-x'),
        _song(id: 'shared', provisional: false, recordingMbid: 'm-x'),
      ]);
      await session.finalize();

      final summary = session.summary;
      expect(summary.aliases, isEmpty);
      expect(summary.canonicalizedSongCount, 1);
      expect(summary.ambiguousMatchCount, 1);
      expect(summary.ambiguousCases.single.canonicalSongId, 'other');
      expect(summary.ambiguousCases.single.candidateIds, <String>['shared']);
      final row = await database.libraryDao.getSongById('shared');
      expect(row!.isProvisional, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test('a uniquely claimed candidate applies at finalize', () async {
    await database
        .into(database.songsTable)
        .insert(_song(id: 'remote-a', provisional: true, recordingMbid: 'm-a'));
    await database
        .into(database.songsTable)
        .insert(
          _song(id: 'canonical-a', provisional: false, recordingMbid: 'm-a'),
        );
    final session = await reconciler.startSession(
      provisionalSongs: <SongsTableData>[
        _song(id: 'remote-a', provisional: true, recordingMbid: 'm-a'),
      ],
    );
    await session.reconcile(<SongsTableData>[
      _song(id: 'canonical-a', provisional: false, recordingMbid: 'm-a'),
    ]);
    await session.finalize();

    final summary = session.summary;
    expect(summary.aliases, hasLength(1));
    expect(summary.canonicalizedSongCount, 1);
    expect(summary.ambiguousMatchCount, 0);
    expect(summary.retainedProvisionalCount, 0);
    expect(await database.libraryDao.getSongById('remote-a'), isNull);
    expect(await database.libraryDao.getSongById('canonical-a'), isNotNull);
  }, skip: !sqliteAvailable);

  // Real server data (2026-11-06, issue #209 item C): Octo-Fiesta still serves
  // Deezer's copy of Adele "Set Fire to the Rain" (21, track 5, 242 s, no
  // MBID) although getSong on that id answers with the library FLAC (238 s).
  // The provisional remote row is never relinked, so Search lists both and
  // the media-info dialog mixes the remote row with the server file.
  test(
    'relinks a remote Deezer copy to the library file of the same track',
    () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: _song(
          id: '7BSVXncc5oeoNO26ypkQrw',
          provisional: false,
          title: 'Set Fire to the Rain',
          artist: 'Adele',
          album: '21',
          duration: 238,
          track: 5,
          recordingMbid: 'd1e0a99e-1894-457b-ba6a-985eeef4d0c4',
        ),
        provisionalSongs: <SongsTableData>[
          _song(
            id: 'ext-deezer-song-8086130',
            provisional: true,
            title: 'Set Fire to the Rain',
            artist: 'Adele',
            album: '21',
            duration: 242,
            track: 5,
          ),
        ],
      );

      expect(result, isA<SongIdentityMatched>());
    },
    skip: !sqliteAvailable,
  );

  test('a 4 s gap without track and disc numbers is not matched', () {
    final result = reconciler.matchCanonicalSong(
      canonicalSong: _song(
        id: 'lib',
        provisional: false,
        duration: 238,
        track: null,
        disc: null,
      ),
      provisionalSongs: <SongsTableData>[
        _song(
          id: 'ext-deezer-song-1',
          provisional: true,
          duration: 242,
          track: null,
          disc: null,
        ),
      ],
    );

    expect(result, isA<SongIdentityUnmatched>());
  }, skip: !sqliteAvailable);

  test(
    'a gap past 2% of the duration is not matched even with equal positions',
    () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: _song(id: 'lib', provisional: false, duration: 238),
        provisionalSongs: <SongsTableData>[
          _song(id: 'ext-deezer-song-1', provisional: true, duration: 244),
        ],
      );

      expect(result, isA<SongIdentityUnmatched>());
    },
    skip: !sqliteAvailable,
  );

  group('relinkExternalCopies', () {
    Future<void> insert(SongsTableData song) =>
        database.into(database.songsTable).insert(song);

    SongsTableData library({
      String id = 'lib',
      String artist = 'Adele',
      String album = '21',
    }) => _song(
      id: id,
      provisional: false,
      title: 'Set Fire to the Rain',
      artist: artist,
      album: album,
      duration: 238,
      track: 5,
      recordingMbid: 'd1e0a99e-1894-457b-ba6a-985eeef4d0c4',
    );

    SongsTableData remote({String artist = 'Adele', String album = '21'}) =>
        _song(
          id: 'ext-deezer-song-8086130',
          provisional: true,
          external: true,
          title: 'Set Fire to the Rain',
          artist: artist,
          album: album,
          duration: 242,
          track: 5,
        );

    test('moves a late remote copy onto the library song', () async {
      final playedAt = DateTime.utc(2026, 11, 6);
      await insert(library());
      await insert(remote());
      await database
          .into(database.playHistoryTable)
          .insert(
            PlayHistoryTableCompanion.insert(
              songId: 'ext-deezer-song-8086130',
              playedAt: playedAt,
            ),
          );

      final count = await reconciler.relinkExternalCopies(<String>[
        'ext-deezer-song-8086130',
      ]);

      expect(count, 1);
      expect(
        await database.libraryDao.getSongById('ext-deezer-song-8086130'),
        isNull,
      );
      final history = await database.select(database.playHistoryTable).get();
      expect(history.single.songId, 'lib');
      expect(
        await database.songIdentityDao.resolveCanonicalId(
          'ext-deezer-song-8086130',
        ),
        'lib',
      );
    }, skip: !sqliteAvailable);

    test('local search then returns one copy', () async {
      await insert(library());
      await insert(remote());
      await database
          .into(database.playHistoryTable)
          .insert(
            PlayHistoryTableCompanion.insert(
              songId: 'ext-deezer-song-8086130',
              playedAt: DateTime.utc(2026, 11, 6),
            ),
          );
      expect(
        (await database.libraryDao.searchCachedSongs('set fire'))
            .map((song) => song.id),
        containsAll(<String>['lib', 'ext-deezer-song-8086130']),
      );

      await reconciler.relinkExternalCopies(<String>[
        'ext-deezer-song-8086130',
      ]);

      expect(
        (await database.libraryDao.searchCachedSongs('set fire'))
            .map((song) => song.id),
        <String>['lib'],
      );
    }, skip: !sqliteAvailable);

    test('leaves a cover by another artist alone', () async {
      await insert(library(artist: 'Adele'));
      await insert(remote(artist: 'No Resolve', album: 'Covers'));

      expect(
        await reconciler.relinkExternalCopies(<String>[
          'ext-deezer-song-8086130',
        ]),
        0,
      );
      expect(
        await database.libraryDao.getSongById('ext-deezer-song-8086130'),
        isNotNull,
      );
    }, skip: !sqliteAvailable);

    test('two library candidates are ambiguous and nothing moves', () async {
      await insert(library());
      await insert(library(id: 'lib-2'));
      await insert(remote());

      expect(
        await reconciler.relinkExternalCopies(<String>[
          'ext-deezer-song-8086130',
        ]),
        0,
      );
      expect(
        await database.libraryDao.getSongById('ext-deezer-song-8086130'),
        isNotNull,
      );
    }, skip: !sqliteAvailable);
  });
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
  bool external = false,
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
    isExternal: external,
  );
}
