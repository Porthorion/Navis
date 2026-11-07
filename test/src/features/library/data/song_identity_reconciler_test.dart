import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/library/data/song_identity_reconciler.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

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

  group('title, artist and duration fallback', () {
    // Real data (2026-11-07, issue #209 item L): Deezer's copy of the single
    // never shares the album, track or disc of the library's album track.
    SongsTableData library({
      String id = 'lib',
      String album = '21',
      int duration = 243,
      String? mbid,
    }) => _song(
      id: id,
      provisional: false,
      title: 'Set Fire to the Rain',
      artist: 'Adele',
      album: album,
      duration: duration,
      track: 2,
      recordingMbid: mbid,
    );

    SongsTableData single({
      String id = 'ext-deezer-song-1',
      int duration = 242,
      String? mbid,
    }) => _song(
      id: id,
      provisional: true,
      external: true,
      title: 'Set Fire to the Rain',
      artist: 'Adele',
      album: 'Set Fire to the Rain - Single',
      duration: duration,
      track: 1,
      recordingMbid: mbid,
    );

    test('a remote single relinks to the library album track', () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: library(),
        provisionalSongs: <SongsTableData>[single()],
      );

      expect(result, isA<SongIdentityMatched>());
      expect(
        (result as SongIdentityMatched).reason,
        SongIdentityMatchReason.titleArtistDuration,
      );
    }, skip: !sqliteAvailable);

    test('a 10 s gap (live or edit) is not matched', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: library(),
          provisionalSongs: <SongsTableData>[single(duration: 233)],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    test('a conflicting recording MBID blocks it', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: library(mbid: 'mbid-a'),
          provisionalSongs: <SongsTableData>[single(mbid: 'mbid-b')],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    test('a missing duration on either side blocks it', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: library(),
          provisionalSongs: <SongsTableData>[
            single().copyWith(duration: const Value(null)),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    test('two remote copies in range are never guessed between', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: library(),
          provisionalSongs: <SongsTableData>[
            single(),
            single(id: 'ext-deezer-song-2', duration: 244),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    test('the exact album tier still wins when it matches', () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: library(),
        provisionalSongs: <SongsTableData>[
          single().copyWith(
            albumName: const Value('21'),
            track: const Value(2),
          ),
        ],
      );

      expect(
        (result as SongIdentityMatched).reason,
        SongIdentityMatchReason.exactMetadata,
      );
    }, skip: !sqliteAvailable);

    SongsTableData interlude({
      String id = 'lib',
      String album = 'Album X',
      int duration = 200,
      int track = 3,
      String title = 'Interlude',
      bool provisional = false,
    }) => _song(
      id: id,
      provisional: provisional,
      title: title,
      artist: 'Artist',
      album: album,
      duration: duration,
      track: track,
    );

    test('the same album with another track number is not matched', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: interlude(track: 9),
          provisionalSongs: <SongsTableData>[
            interlude(id: 'ext-deezer-song-1', provisional: true),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    test('tracks under 90 s are not matched by title and artist', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: interlude(duration: 45, album: 'Album X'),
          provisionalSongs: <SongsTableData>[
            interlude(
              id: 'ext-deezer-song-1',
              provisional: true,
              album: 'Intro - Single',
              duration: 47,
            ),
          ],
        ),
        isA<SongIdentityUnmatched>(),
      );
    }, skip: !sqliteAvailable);

    for (final (name, canonicalAlbum, provisionalAlbum, provisionalTitle)
        in <(String, String, String, String)>[
          ('live album', 'Album X', 'Album X (Live)', 'Interlude'),
          ('live title', 'Album X', 'Interlude - Single', 'Interlude - Live'),
          ('remix title', 'Album X', 'Interlude - Single', 'Interlude (Remix)'),
          ('demo album', 'Album X (Demo)', 'Interlude - Single', 'Interlude'),
        ]) {
      test('a version word on one side only blocks it ($name)', () {
        expect(
          reconciler.matchCanonicalSong(
            canonicalSong: interlude(album: canonicalAlbum),
            provisionalSongs: <SongsTableData>[
              interlude(
                id: 'ext-deezer-song-1',
                provisional: true,
                album: provisionalAlbum,
                title: provisionalTitle,
                duration: 201,
              ),
            ],
          ),
          isA<SongIdentityUnmatched>(),
        );
      }, skip: !sqliteAvailable);
    }

    test('a version word on both sides still matches', () {
      expect(
        reconciler.matchCanonicalSong(
          canonicalSong: interlude(album: 'Album X (Live)'),
          provisionalSongs: <SongsTableData>[
            interlude(
              id: 'ext-deezer-song-1',
              provisional: true,
              album: 'Interlude - Single (Live)',
              duration: 201,
            ),
          ],
        ),
        isA<SongIdentityMatched>(),
      );
    }, skip: !sqliteAvailable);

    test('a weak claim contested across pages is dropped silently', () async {
      final session = await reconciler.startSession(
        provisionalSongs: <SongsTableData>[single()],
      );
      await session.reconcile(<SongsTableData>[library()]);
      await session.reconcile(<SongsTableData>[
        library(id: 'lib-2', album: 'Now 80'),
      ]);
      await session.finalize();

      final summary = session.summary;
      expect(summary.aliases, isEmpty);
      expect(summary.canonicalizedSongCount, 0);
      expect(summary.ambiguousMatchCount, 0);
      expect(summary.ambiguousCases, isEmpty);
      expect(summary.retainedProvisionalCount, 1);
    }, skip: !sqliteAvailable);

    test('a straight apostrophe matches a curly one', () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: _song(
          id: 'lib',
          provisional: false,
          title: 'Don\u2019t You Remember',
        ),
        provisionalSongs: <SongsTableData>[
          _song(
            id: 'ext-deezer-song-1',
            provisional: true,
            title: "Don't You Remember",
          ),
        ],
      );

      expect(
        (result as SongIdentityMatched).reason,
        SongIdentityMatchReason.exactMetadata,
      );
    }, skip: !sqliteAvailable);

    test('typographic dashes and double quotes fold too', () {
      final result = reconciler.matchCanonicalSong(
        canonicalSong: _song(
          id: 'lib',
          provisional: false,
          title: '\u201CHeroes\u201D \u2013 Live',
        ),
        provisionalSongs: <SongsTableData>[
          _song(
            id: 'ext-deezer-song-1',
            provisional: true,
            title: '"Heroes" - Live',
          ),
        ],
      );

      expect(result, isA<SongIdentityMatched>());
    }, skip: !sqliteAvailable);
  });

  group('relinkExternalCopies', () {
    Future<void> insert(SongsTableData song) =>
        database.into(database.songsTable).insert(song);

    // Candidates come from the search index, so bring it up to date first.
    Future<Map<String, String>> refreshAndRelink(List<String> ids) async {
      await database.libraryDao.scheduleSongSearchIndexRefresh();
      return reconciler.relinkExternalCopies(ids);
    }

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

      final linked = await refreshAndRelink(<String>[
        'ext-deezer-song-8086130',
      ]);

      expect(linked, {'ext-deezer-song-8086130': 'lib'});
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

    for (final title in ['Été Indien', 'Группа крови']) {
      test('relinks a non-ASCII title ($title)', () async {
        await insert(library().copyWith(title: title));
        await insert(remote().copyWith(title: title.toUpperCase()));

        expect(
          await refreshAndRelink(<String>['ext-deezer-song-8086130']),
          hasLength(1),
        );
        expect(
          await database.libraryDao.getSongById('ext-deezer-song-8086130'),
          isNull,
        );
      }, skip: !sqliteAvailable);
    }

    // The candidate query uses the indexed match_title (normalizeMetadata).
    // Titles the reconciler treats as equal must share it, or the relink
    // would never see the library song. Known gap (ponytail comment on the
    // DAO query): "Song (Live)" vs "Song [Live]" differ in match_title.
    for (final (a, b) in <(String, String)>[
      ('Été Indien', 'ÉTÉ INDIEN'),
      ('Группа крови', 'ГРУППА КРОВИ'),
      ("Rock'n'Roll", 'Rock n Roll'),
      ('AC/DC', 'AC DC'),
      ('Hello!', 'hello'),
    ]) {
      test('match_title agrees with the reconciler key: $a / $b', () async {
        final result = reconciler.matchCanonicalSong(
          canonicalSong: library().copyWith(title: a),
          provisionalSongs: <SongsTableData>[remote().copyWith(title: b)],
        );
        expect(result, isA<SongIdentityMatched>());
        expect(normalizeMetadata(a), normalizeMetadata(b));

        await insert(library().copyWith(title: a));
        await insert(remote().copyWith(title: b));
        await database.libraryDao.scheduleSongSearchIndexRefresh();
        expect(
          await refreshAndRelink(<String>['ext-deezer-song-8086130']),
          hasLength(1),
        );
      }, skip: !sqliteAvailable);
    }

    test('the playing remote copy keeps its cache file', () async {
      final directory = await Directory.systemTemp.createTemp('navis-relink-');
      addTearDown(() => directory.delete(recursive: true));
      final remoteFile = File('${directory.path}/remote.audio')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final libraryFile = File('${directory.path}/library.audio')
        ..writeAsBytesSync(<int>[4, 5, 6, 7]);
      await insert(library());
      await insert(remote());
      for (final (id, file, type) in [
        ('ext-deezer-song-8086130', remoteFile, CacheType.rolling),
        ('lib', libraryFile, CacheType.permanent),
      ]) {
        await database.cacheDao.upsertCachedTrack(
          CachedTracksTableCompanion.insert(
            songId: id,
            filePath: file.path,
            fileSize: file.lengthSync(),
            format: 'mp3',
            lastAccessedAt: DateTime.now(),
            cacheType: type,
            downloadStatus: DownloadStatus.complete,
          ),
        );
      }
      await database.libraryDao.scheduleSongSearchIndexRefresh();

      final linked = await SongIdentityReconciler(
        database.songIdentityDao,
        readActiveSongId: () => 'ext-deezer-song-8086130',
      ).relinkExternalCopies(<String>['ext-deezer-song-8086130']);

      expect(linked, hasLength(1));
      expect(remoteFile.existsSync(), isTrue);
    }, skip: !sqliteAvailable);

    test('a batch of more than 1000 ids still relinks', () async {
      await insert(library());
      await insert(remote());
      await database.libraryDao.scheduleSongSearchIndexRefresh();
      final ids = <String>[
        for (var i = 0; i < 1500; i++) 'ext-deezer-song-none-$i',
        'ext-deezer-song-8086130',
      ];

      expect(await reconciler.relinkExternalCopies(ids), hasLength(1));
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

      await refreshAndRelink(<String>['ext-deezer-song-8086130']);

      expect(
        (await database.libraryDao.searchCachedSongs('set fire'))
            .map((song) => song.id),
        <String>['lib'],
      );
    }, skip: !sqliteAvailable);

    SongsTableData albumTrack({String id = 'lib', String album = '21'}) =>
        _song(
          id: id,
          provisional: false,
          title: 'Set Fire to the Rain',
          artist: 'Adele',
          album: album,
          duration: 243,
          track: 2,
        );

    test('a remote single relinks and search returns one row', () async {
      await insert(albumTrack());
      await insert(
        remote(album: 'Set Fire to the Rain - Single')
            .copyWith(duration: const Value(242), track: const Value(1)),
      );
      await database
          .into(database.playHistoryTable)
          .insert(
            PlayHistoryTableCompanion.insert(
              songId: 'ext-deezer-song-8086130',
              playedAt: DateTime.utc(2026, 11, 7),
            ),
          );

      expect(await refreshAndRelink(<String>['ext-deezer-song-8086130']), {
        'ext-deezer-song-8086130': 'lib',
      });
      expect(
        (await database.libraryDao.searchCachedSongs('set fire'))
            .map((song) => song.id),
        <String>['lib'],
      );
      expect(
        (await database.songIdentityDao.getAliases()).single.matchReason,
        'titleArtistDuration',
      );
    }, skip: !sqliteAvailable);

    test('the same song on an album and a compilation never relinks', () async {
      await insert(albumTrack());
      await insert(albumTrack(id: 'lib-2', album: 'Now 80'));
      await insert(
        remote(album: 'Set Fire to the Rain - Single')
            .copyWith(duration: const Value(242), track: const Value(1)),
      );

      expect(
        await refreshAndRelink(<String>['ext-deezer-song-8086130']),
        isEmpty,
      );
      expect(
        await database.libraryDao.getSongById('ext-deezer-song-8086130'),
        isNotNull,
      );
    }, skip: !sqliteAvailable);

    test('an exact album match is not blocked by a compilation', () async {
      await insert(albumTrack());
      await insert(albumTrack(id: 'lib-2', album: 'Now 80'));
      await insert(
        remote().copyWith(duration: const Value(243), track: const Value(2)),
      );

      expect(await refreshAndRelink(<String>['ext-deezer-song-8086130']), {
        'ext-deezer-song-8086130': 'lib',
      });
    }, skip: !sqliteAvailable);

    test('a stale search index never lets the weak tier merge', () async {
      Future<void> insertAlbumTrack(String id, String album, int duration) =>
          insert(
            _song(
              id: id,
              provisional: false,
              title: 'Interlude',
              artist: 'Artist',
              album: album,
              duration: duration,
              track: 3,
            ),
          );
      await insertAlbumTrack('lib-1', 'Album A', 200);
      await database.libraryDao.scheduleSongSearchIndexRefresh();
      // Inserted after the refresh, so the match index has not seen it yet.
      await insertAlbumTrack('lib-2', 'Album B', 201);
      await insert(
        _song(
          id: 'ext-deezer-song-1',
          provisional: true,
          external: true,
          title: 'Interlude',
          artist: 'Artist',
          album: 'Interlude - Single',
          duration: 200,
          track: 1,
        ),
      );

      expect(
        await reconciler.relinkExternalCopies(<String>['ext-deezer-song-1']),
        isEmpty,
      );
      // Once the index is current both candidates are visible: still ambiguous.
      expect(await refreshAndRelink(<String>['ext-deezer-song-1']), isEmpty);
      expect(
        await database.libraryDao.getSongById('ext-deezer-song-1'),
        isNotNull,
      );
    }, skip: !sqliteAvailable);

    test('a stale index still lets the exact tier relink', () async {
      await insert(library());
      await database.libraryDao.scheduleSongSearchIndexRefresh();
      await insert(library(id: 'unrelated').copyWith(title: 'Other Song'));
      await insert(remote());

      expect(
        await reconciler.relinkExternalCopies(<String>[
          'ext-deezer-song-8086130',
        ]),
        {'ext-deezer-song-8086130': 'lib'},
      );
    }, skip: !sqliteAvailable);

    test('a live version 10 s longer is left alone', () async {
      await insert(albumTrack());
      await insert(remote(album: 'Live').copyWith(duration: const Value(253)));

      expect(
        await refreshAndRelink(<String>['ext-deezer-song-8086130']),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('leaves a cover by another artist alone', () async {
      await insert(library(artist: 'Adele'));
      await insert(remote(artist: 'No Resolve', album: 'Covers'));

      expect(
        await refreshAndRelink(<String>['ext-deezer-song-8086130']),
        isEmpty,
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
        await refreshAndRelink(<String>['ext-deezer-song-8086130']),
        isEmpty,
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
