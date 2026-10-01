import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';

import '../../../helpers/test_database.dart';

AlbumsTableCompanion _album(
  String id, {
  String? artistId,
  String? artistName,
  List<ArtistRef> credits = const <ArtistRef>[],
  bool provisional = false,
  bool external = false,
}) => AlbumsTableCompanion.insert(
  id: id,
  name: 'Album $id',
  artistId: Value(artistId),
  artistName: Value(artistName),
  artists: Value(credits),
  isProvisional: Value(provisional),
  isExternal: Value(external),
);

SongsTableCompanion _song(
  String id,
  String title, {
  String? artistId,
  String? artistName,
  String? albumId,
  String? albumName,
}) => SongsTableCompanion.insert(
  id: id,
  title: title,
  artistId: Value(artistId),
  artistName: Value(artistName),
  albumId: Value(albumId),
  albumName: Value(albumName),
);

void main() {
  late NavisDatabase database;

  setUp(() async {
    database = createTestDatabase();
    await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(id: 'sq', name: 'Square Enix Music'),
      ArtistsTableCompanion.insert(id: 'other', name: 'Other Artist'),
    ]);
    // Inserted directly: the sync upsert normalizes provisional flags.
    await database.batch(
      (batch) => batch.insertAll(database.albumsTable, <AlbumsTableCompanion>[
        _album('by-id', artistId: 'sq', artistName: 'Square Enix Music'),
        _album('by-name', artistName: 'SQUARE ENIX MUSIC (feat. Guest)'),
        _album('near-name', artistName: 'Square Enix Musical'),
        _album(
          'credit-id',
          artistId: 'other',
          credits: const <ArtistRef>[ArtistRef(id: 'sq', name: 'Renamed')],
        ),
        _album(
          'credit-name',
          artistId: 'other',
          credits: const <ArtistRef>[
            ArtistRef(id: 'zz', name: 'Square-Enix Music'),
          ],
        ),
        _album('related', artistId: 'other'),
        _album('unrelated', artistId: 'other'),
        _album('hidden', artistId: 'sq', provisional: true),
        _album('remote', artistId: 'sq', provisional: true, external: true),
      ]),
    );
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      _song('guest', 'Guest Spot', artistId: 'sq', albumId: 'related'),
    ]);
  });

  tearDown(() => database.close());

  Future<void> expectBucketsMatchFullScan(String artistId) async {
    final indexed = await database.libraryDao
        .watchArtistAlbumBuckets(artistId)
        .first;
    final scanned = await database.libraryDao.debugArtistAlbumBucketsByFullScan(
      artistId,
    );
    expect(
      indexed.primaryAlbums.map((album) => album.id),
      scanned.primaryAlbums.map((album) => album.id),
    );
    expect(
      indexed.featuredInAlbums.map((album) => album.id),
      scanned.featuredInAlbums.map((album) => album.id),
    );
  }

  test('artist buckets from the index equal a full-library scan', () async {
    final buckets = await database.libraryDao
        .watchArtistAlbumBuckets('sq')
        .first;
    expect(buckets.primaryAlbums.map((album) => album.id).toSet(), <String>{
      'by-id',
      'by-name',
      'remote',
    });
    expect(buckets.featuredInAlbums.map((album) => album.id).toSet(), <String>{
      'credit-id',
      'credit-name',
      'related',
    });
    await expectBucketsMatchFullScan('sq');
    await expectBucketsMatchFullScan('other');
  });

  test(
    'an index refresh that cannot settle stops instead of looping',
    () async {
      // More than a refresh batch of albums, and every write is spoiled, so
      // the rows always look stale and every batch is full.
      await database.batch(
        (batch) => batch.insertAll(database.albumsTable, <AlbumsTableCompanion>[
          for (var i = 0; i < 1200; i++) _album('stale-$i', artistId: 'other'),
        ]),
      );
      for (final event in <String>['INSERT', 'UPDATE']) {
        await database.customStatement('''
        CREATE TEMP TRIGGER spoil_album_artist_index_$event
        AFTER $event ON album_artist_index
        WHEN NEW.source <> 'spoiled'
        BEGIN
          UPDATE album_artist_index SET source = 'spoiled'
          WHERE album_id = NEW.album_id;
        END;
      ''');
      }
      final written = await database.libraryDao
          .refreshAlbumArtistIndex()
          .timeout(const Duration(seconds: 10));
      expect(written, greaterThan(0));
    },
  );

  test(
    'artist snapshots and index refreshes overlap without stalling',
    () async {
      // Enough stale albums that refreshes take several batches.
      await database.batch(
        (batch) => batch.insertAll(database.albumsTable, <AlbumsTableCompanion>[
          for (var i = 0; i < 2500; i++)
            _album('bulk-$i', artistId: i.isEven ? 'sq' : 'other'),
        ]),
      );
      final work = <Future<Object?>>[];
      for (var round = 0; round < 6; round++) {
        work
          ..add(database.libraryDao.refreshAlbumArtistIndex())
          ..add(database.libraryDao.getArtistPlaybackSnapshot('sq'))
          ..add(
            database.batch(
              (batch) =>
                  batch.insertAll(database.albumsTable, <AlbumsTableCompanion>[
                    for (var i = 0; i < 200; i++)
                      _album('late-$round-$i', artistId: 'sq'),
                  ]),
            ),
          )
          ..add(database.libraryDao.getArtistPlaybackSnapshot('other'));
      }
      await Future.wait(work).timeout(const Duration(seconds: 60));
      await expectBucketsMatchFullScan('sq');
      await expectBucketsMatchFullScan('other');
    },
  );

  test('album writes are picked up without any index maintenance', () async {
    final updates = database.libraryDao.watchArtistAlbumBuckets('sq');
    final seen = <Set<String>>[];
    final subscription = updates.listen(
      (buckets) => seen.add(<String>{
        ...buckets.primaryAlbums.map((album) => album.id),
        ...buckets.featuredInAlbums.map((album) => album.id),
      }),
    );
    addTearDown(subscription.cancel);
    await pumpEventQueue();
    await (database.update(
      database.albumsTable,
    )..where((album) => album.id.equals('unrelated'))).write(
      const AlbumsTableCompanion(
        artists: Value(<ArtistRef>[ArtistRef(id: 'sq', name: 'x')]),
      ),
    );
    for (
      var i = 0;
      i < 100 && !(seen.lastOrNull?.contains('unrelated') ?? false);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(seen.last, contains('unrelated'));
    await expectBucketsMatchFullScan('sq');
  });

  group('track match candidates', () {
    setUp(() async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        _song('t1', 'Snow In Summer', artistName: 'Square Enix Music'),
        _song('t2', 'Snow in Summer (Live)', artistName: 'Keiichi Okabe'),
        _song('t3', 'Kainé', artistName: 'Square Enix Music feat. Emi Evans'),
        _song('t4', 'Weight of the World', artistName: 'Okabe Keiichi'),
        _song('t5', 'Unrelated', artistName: 'Someone Else'),
        _song('t6', 'Grandma', artistName: 'Keiichi'),
      ]);
    });

    const queries = <TrackMatchQuery>[
      TrackMatchQuery(title: 'Snow in Summer', artist: 'Square Enix Music'),
      TrackMatchQuery(title: 'Kaine', artist: 'SQUARE ENIX MUSIC'),
      TrackMatchQuery(title: 'Weight of the World', artist: 'NieR'),
      TrackMatchQuery(title: 'Grandma (Destruction)', artist: 'Keiichi Okabe'),
      TrackMatchQuery(title: 'Nothing Here', artist: 'Nobody'),
    ];

    Future<List<String?>> matches(List<SongsTableData> songs) async {
      final snapshot = await LocalTrackMatchSnapshot.fromSongsAsync(songs);
      return <String?>[
        for (final query in queries)
          pickBestTrackMatch(
            track: query,
            candidates: snapshot.candidatesFor(query),
          ).song?.id,
      ];
    }

    Future<List<SongsTableData>> candidates() =>
        database.libraryDao.getTrackMatchCandidates(
          queries.map((query) => (title: query.title, artist: query.artist)),
        );

    test('match exactly like the whole library, stale or fresh', () async {
      final reference = await matches(await database.libraryDao.getAllSongs());
      // Before the refresh every row is stale and is a candidate.
      expect(await matches(await candidates()), reference);
      await database.libraryDao.refreshSongSearchIndex();
      final fresh = await candidates();
      expect(await matches(fresh), reference);
      // Fresh keys narrow the candidates to songs that could match.
      expect(fresh.map((song) => song.id), isNot(contains('t5')));
    });

    test('the indexed lookup returns exactly the full-scan rows', () async {
      // Words that are substrings of each other, one-letter words, accents
      // and punctuation, so containment and shared-word matches overlap.
      const words = <String>[
        'Okabe',
        'Okab',
        'abe',
        'Keiichi',
        'Kei',
        'A',
        'x',
        'Square',
        'Enix',
        'Music',
        'feat.',
        'Emi',
        'Évans',
        'evans',
        'The',
        'AC/DC',
        '',
        ' ',
      ];
      for (var seed = 0; seed < 25; seed++) {
        final random = math.Random(seed);
        String phrase(int maxWords) => List<String>.generate(
          random.nextInt(maxWords + 1),
          (_) => words[random.nextInt(words.length)],
        ).join(' ');
        await database.customStatement('DELETE FROM song_search_text');
        await database.customStatement('DELETE FROM songs');
        final songs = <SongsTableCompanion>[
          for (var i = 0; i < 60; i++)
            SongsTableCompanion.insert(
              id: 's$seed-$i',
              title: phrase(3),
              artistName: Value(random.nextInt(8) == 0 ? null : phrase(4)),
              isProvisional: Value(random.nextInt(10) == 0),
              serverDeletedAt: Value(
                random.nextInt(10) == 0 ? DateTime.utc(2026) : null,
              ),
            ),
        ];
        await database.batch(
          (batch) => batch.insertAll(database.songsTable, songs.sublist(0, 50)),
        );
        await database.libraryDao.refreshSongSearchIndex();
        // Songs added since the refresh have no index row.
        await database.batch(
          (batch) => batch.insertAll(database.songsTable, songs.sublist(50)),
        );
        for (var round = 0; round < 8; round++) {
          // Songs renamed since the last refresh have stale keys.
          for (var i = 0; i < 5; i++) {
            await database.customStatement(
              'UPDATE songs SET artist_name = ? WHERE id = ?',
              <Object?>[phrase(3), 's$seed-${random.nextInt(50)}'],
            );
          }
          final tracks = <({String title, String artist})>[
            for (var i = random.nextInt(6); i >= 0; i--)
              (title: phrase(3), artist: phrase(3)),
          ];
          final reference = await database.libraryDao
              .debugTrackMatchCandidatesByFullScan(tracks);
          final indexed = await database.libraryDao.getTrackMatchCandidates(
            tracks,
          );
          expect(
            indexed.map((song) => song.id).toSet(),
            reference.map((song) => song.id).toSet(),
            reason: 'seed $seed round $round tracks $tracks',
          );
          expect(indexed, hasLength(reference.length));
          // Let the refresh the stale rows started finish before the next
          // round changes the library.
          await database.libraryDao.scheduleSongSearchIndexRefresh();
        }
      }
    });
  });
}
