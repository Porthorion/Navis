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
    expect(
      buckets.primaryAlbums.map((album) => album.id).toSet(),
      <String>{'by-id', 'by-name', 'remote'},
    );
    expect(
      buckets.featuredInAlbums.map((album) => album.id).toSet(),
      <String>{'credit-id', 'credit-name', 'related'},
    );
    await expectBucketsMatchFullScan('sq');
    await expectBucketsMatchFullScan('other');
  });

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
      final reference = await matches(
        await database.libraryDao.getAllSongs(),
      );
      // Before the refresh every row is stale and is a candidate.
      expect(await matches(await candidates()), reference);
      await database.libraryDao.refreshSongSearchIndex();
      final fresh = await candidates();
      expect(await matches(fresh), reference);
      // Fresh keys narrow the candidates to songs that could match.
      expect(fresh.map((song) => song.id), isNot(contains('t5')));
    });
  });
}
