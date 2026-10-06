import 'dart:async';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/daos/library_dao.dart';
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

class _ControlledRefreshDao extends LibraryDao {
  new(super.attachedDatabase);

  int refreshCalls = 0;
  Completer<void>? refreshGate;

  @override
  Future<int> refreshSongSearchIndex({int batchSize = 2000}) async {
    refreshCalls++;
    await refreshGate?.future;
    return await super.refreshSongSearchIndex(batchSize: batchSize);
  }
}

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

  test(
    'artist navigation reuses a unique loose name and invalidates on writes',
    () async {
      await database.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'peas', name: 'The Black Eyed Peas'),
      ]);
      expect(
        (await database.libraryDao.findOneExactNormalizedArtistByName(
          'Black Eyed Peas',
        ))?.id,
        'peas',
      );
      await database.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'other-peas', name: 'Black-Eyed Peas'),
      ]);
      expect(
        await database.libraryDao.findOneExactNormalizedArtistByName(
          'BlackEyedPeas',
        ),
        isNull,
      );
      expect(
        (await database.libraryDao.findOneExactNormalizedArtistByName(
          'The Black Eyed Peas',
        ))?.id,
        'peas',
      );
    },
  );

  test('artist navigation rejects uncorroborated spacing-only links', () async {
    await database.libraryDao.upsertArtists([
      ArtistsTableCompanion.insert(id: 'star', name: 'Blackstar'),
    ]);
    expect(
      await database.libraryDao.findOneExactNormalizedArtistByName(
        'Black Star',
      ),
      isNull,
    );
  });

  test('indexed artist fallback requires equality for short keys', () async {
    await database.libraryDao.upsertSongs([
      _song('x', 'Song', artistName: 'X'),
      _song('xx', 'Other', artistName: 'XX'),
      _song('arashi', '花', artistName: '嵐'),
      _song('other-arashi', 'Other', artistName: '嵐山'),
      _song('supplementary', '花', artistName: '𠮷'),
      _song('other-supplementary', 'Other', artistName: '𠮷田'),
    ]);
    await database.libraryDao.refreshSongSearchIndex();
    for (final (artist, id) in [
      ('X', 'x'),
      ('嵐', 'arashi'),
      ('𠮷', 'supplementary'),
    ]) {
      final candidates = await database.libraryDao.getTrackMatchCandidates([
        (title: 'Unknown', artist: artist),
      ]);
      expect(candidates.map((song) => song.id), [id]);
    }
  });

  for (final refreshAlreadyPending in [false, true]) {
    test('upgrade refresh finishes before track candidate matching '
        '(already pending: $refreshAlreadyPending)', () async {
      await database.libraryDao.upsertSongs([
        _song('target', '残響リファレンス', artistName: '嵐'),
        _song('unrelated', 'Unrelated', artistName: 'Other'),
      ]);
      await database.libraryDao.refreshSongSearchIndex();
      await database.customStatement(
        "UPDATE song_search_text SET source = substr(source, 1, length(source) - 1) || '1', match_title = ''",
      );
      var refreshFinished = false;
      final pending = refreshAlreadyPending
          ? database.libraryDao.scheduleSongSearchIndexRefresh().then((_) {
              refreshFinished = true;
            })
          : null;
      final candidates = await database.libraryDao.getTrackMatchCandidates([
        (title: '残響リファレンス', artist: '嵐'),
      ]);
      if (refreshAlreadyPending) expect(refreshFinished, isTrue);
      final row = await database
          .customSelect(
            "SELECT match_title FROM song_search_text WHERE song_id = 'target'",
          )
          .getSingle();
      expect(row.read<String>('match_title'), '残響リファレンス');
      expect(candidates.map((song) => song.id), ['target']);
      await pending;
      await database.libraryDao.scheduleSongSearchIndexRefresh();
    });
  }

  for (final fullScan in [false, true]) {
    Future<List<SongsTableData>> match(_ControlledRefreshDao dao) => fullScan
        ? dao.debugTrackMatchCandidatesByFullScan([
            (title: 'Target', artist: 'Artist'),
          ])
        : dao.getTrackMatchCandidates([(title: 'Target', artist: 'Artist')]);

    test(
      'fresh matching starts no refresh writes (full scan: $fullScan)',
      () async {
        await database.libraryDao.upsertSongs([
          _song('target', 'Target', artistName: 'Artist'),
        ]);
        await database.libraryDao.refreshSongSearchIndex();
        final dao = _ControlledRefreshDao(database);
        expect((await match(dao)).map((song) => song.id), ['target']);
        expect(dao.refreshCalls, 0);
      },
    );

    for (final alreadyRunning in [false, true]) {
      test('matching times out its refresh wait and retains stale candidates '
          '(full scan: $fullScan, running: $alreadyRunning)', () async {
        await database.libraryDao.upsertSongs([
          _song('target', 'Target', artistName: 'Artist'),
        ]);
        final gate = Completer<void>();
        final dao = _ControlledRefreshDao(database)..refreshGate = gate;
        final pending = alreadyRunning
            ? dao.scheduleSongSearchIndexRefresh()
            : null;
        try {
          expect(
            (await match(dao).timeout(const Duration(seconds: 3)))
                .map((song) => song.id),
            contains('target'),
          );
          expect(dao.refreshCalls, 1);
        } finally {
          gate.complete();
          await (pending ?? dao.scheduleSongSearchIndexRefresh());
        }
      });
    }
  }

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
      // The first lookup refreshes stale rows before selecting candidates.
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

  group('non-Latin metadata', () {
    setUp(() async {
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'oor', name: 'ワンオクロック'),
        ArtistsTableCompanion.insert(id: 'oor-latin', name: 'ONE OK ROCK'),
      ]);
      await database.batch(
        (batch) => batch.insertAll(database.albumsTable, <AlbumsTableCompanion>[
          _album('jp-name', artistName: 'ワンオクロック'),
          _album('full-width', artistName: 'ＯＮＥ　ＯＫ　ＲＯＣＫ'),
        ]),
      );
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        _song('jp1', '残響リファレンス', artistName: 'ワンオクロック'),
        _song('jp2', '完全感覚Dreamer', artistName: 'ワンオクロック'),
        _song('beyonce', 'Halo', artistName: 'Beyoncé'),
      ]);
    });

    test('Japanese titles and artists are track-match candidates', () async {
      await database.libraryDao.refreshSongSearchIndex();
      const tracks = <({String title, String artist})>[
        (title: '「残響リファレンス」', artist: 'ワンオクロック'),
      ];
      final candidates = await database.libraryDao.getTrackMatchCandidates(
        tracks,
      );
      expect(
        candidates.map((song) => song.id).toSet(),
        containsAll(<String>['jp1', 'jp2']),
      );
      expect(candidates.map((song) => song.id), isNot(contains('beyonce')));
      final snapshot = await LocalTrackMatchSnapshot.fromSongsAsync(candidates);
      const query = TrackMatchQuery(title: '「残響リファレンス」', artist: 'ワンオクロック');
      expect(
        pickBestTrackMatch(
          track: query,
          candidates: snapshot.candidatesFor(query),
        ).song?.id,
        'jp1',
      );
    });

    test('keys written by an older normalizer are re-keyed', () async {
      await database.libraryDao.refreshSongSearchIndex();
      // What a build with the ASCII-only normalizer stored: the plain source
      // and keys with every non-ASCII letter stripped.
      await database.customStatement(
        'UPDATE song_search_text SET source = (SELECT songs.title || char(31) '
        "|| ifnull(songs.artist_name, '') || char(31) "
        "|| ifnull(songs.album_name, '') FROM songs "
        'WHERE songs.id = song_search_text.song_id), '
        "match_title = '', match_artist = '' "
        "WHERE song_id IN ('jp1', 'beyonce')",
      );
      expect(await database.libraryDao.refreshSongSearchIndex(), 2);
      final rows = await database
          .customSelect(
            'SELECT song_id, match_title, match_artist FROM song_search_text '
            "WHERE song_id IN ('jp1', 'beyonce') ORDER BY song_id",
          )
          .get();
      expect(
        rows.map(
          (row) => (
            row.read<String>('match_title'),
            row.read<String>('match_artist'),
          ),
        ),
        <(String, String)>[('halo', 'beyonce'), ('残響リファレンス', 'ワンオクロック')],
      );
    });

    test('legacy search text is reused until the background re-key finishes', () async {
      await database.libraryDao.refreshSongSearchIndex();
      // An older build wrote search text using the previous folding rules.
      // A marker proves search reuses the row while raw metadata is unchanged.
      await database.customStatement(
        'UPDATE song_search_text SET source = (SELECT songs.title || char(31) '
        "|| ifnull(songs.artist_name, '') || char(31) "
        "|| ifnull(songs.album_name, '') FROM songs "
        'WHERE songs.id = song_search_text.song_id), '
        "search_text = 'zzmarker|beyonce|' WHERE song_id = 'beyonce'",
      );
      final legacy = await database.libraryDao.searchCachedSongs('zzmarker');
      expect(legacy.map((song) => song.id), <String>['beyonce']);
      await database.libraryDao.scheduleSongSearchIndexRefresh();
      final found = await database.libraryDao.searchCachedSongs('halo');
      expect(found.map((song) => song.id), <String>['beyonce']);
      expect(await database.libraryDao.searchCachedSongs('zzmarker'), isEmpty);
      // Matching awaits re-keying and excludes unrelated stale songs.
      final candidates = await database.libraryDao.getTrackMatchCandidates(
        const <({String title, String artist})>[
          (title: 'Nothing', artist: 'Nobody'),
        ],
      );
      expect(candidates, isEmpty);
    });

    test('a Japanese name-only album is on its artist page, even from an '
        'index written by an older normalizer', () async {
      Future<Set<String>> primary(String artistId) async =>
          (await database.libraryDao.watchArtistAlbumBuckets(artistId).first)
              .primaryAlbums
              .map((album) => album.id)
              .toSet();

      expect(await primary('oor'), contains('jp-name'));
      expect(await primary('oor-latin'), contains('full-width'));
      await expectBucketsMatchFullScan('oor');

      // What a build with the ASCII-only normalizer stored: the plain source
      // and no name key for a Japanese album artist.
      await database.customStatement(
        "UPDATE album_artist_index SET artist_keys = '', source = "
        "(SELECT ifnull(a.artist_id, '') || char(31) "
        "|| ifnull(a.artist_name, '') || char(31) || a.artists "
        'FROM albums a WHERE a.id = album_artist_index.album_id) '
        "WHERE album_id = 'jp-name'",
      );
      expect(await primary('oor'), contains('jp-name'));
    });

    test(
      'same-edition contextual lookup prefers a raw title then the smallest id',
      () async {
        await database.libraryDao.upsertSongs([
          _song('z-remaster', 'Song (Remastered)', artistName: '嵐'),
          _song('a-raw', 'Song', artistName: '嵐'),
          _song('0-first', 'Song (Deluxe Edition)', artistName: '嵐'),
        ]);
        await database.customStatement('PRAGMA reverse_unordered_selects = ON');
        expect(
          (await database.libraryDao.findOneExactNormalizedSongByTitle(
            'Song',
            artistName: '嵐',
          ))?.id,
          'a-raw',
        );
        expect(
          (await database.libraryDao.findOneExactNormalizedSongByTitle(
            'Song (Remastered)',
            artistName: '嵐',
          ))?.id,
          'z-remaster',
        );
        expect(
          (await database.libraryDao.findOneExactNormalizedSongByTitle(
            'Song (2011 Remaster)',
            artistName: '嵐',
          ))?.id,
          '0-first',
        );
      },
    );

    test(
      'unfiltered namesakes stay ambiguous for missing artist context',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'abba-hits',
            name: 'Greatest Hits',
            artistName: const Value('ABBA'),
          ),
          AlbumsTableCompanion.insert(
            id: 'blondie-hits',
            name: 'Greatest Hits',
            artistName: const Value('Blondie'),
          ),
        ]);
        await database.libraryDao.upsertSongs([
          _song('abba-song', 'Greatest Hits', artistName: 'ABBA'),
          _song('blondie-song', 'Greatest Hits', artistName: 'Blondie'),
        ]);
        for (final artist in [null, 'Queen']) {
          expect(
            await database.libraryDao.findOneExactNormalizedAlbumByName(
              'Greatest Hits',
              artistName: artist,
            ),
            isNull,
          );
          expect(
            await database.libraryDao.findOneExactNormalizedSongByTitle(
              'Greatest Hits',
              artistName: artist,
            ),
            isNull,
          );
        }
      },
    );

    test(
      'contextual album ties use id order rather than insertion order',
      () async {
        await database.libraryDao.upsertAlbums([
          AlbumsTableCompanion.insert(
            id: 'z-hits',
            name: 'Greatest Hits',
            artistName: const Value('Queen'),
          ),
          AlbumsTableCompanion.insert(
            id: 'a-hits',
            name: 'Greatest Hits (Remastered)',
            artistName: const Value('Queen'),
          ),
        ]);
        await database.customStatement('PRAGMA reverse_unordered_selects = ON');
        expect(
          (await database.libraryDao.findOneExactNormalizedAlbumByName(
            'Greatest Hits (2011 Remaster)',
            artistName: 'Queen',
          ))?.id,
          'a-hits',
        );
        expect(
          (await database.libraryDao.findOneExactNormalizedAlbumByName(
            'Greatest Hits',
            artistName: 'Queen',
          ))?.id,
          'z-hits',
        );
      },
    );

    test('an exact lookup prefers the same language version', () async {
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        _song('wonder', 'Wonder', artistName: 'ONE OK ROCK'),
        _song(
          'wonder-jp',
          'Wonder (Japanese Version)',
          artistName: 'ONE OK ROCK',
        ),
      ]);
      Future<String?> lookup(String title) async =>
          (await database.libraryDao.findOneExactNormalizedSongByTitle(
            title,
            artistName: 'ONE OK ROCK',
          ))?.id;

      expect(await lookup('Wonder (Japanese Version)'), 'wonder-jp');
      expect(await lookup('Wonder'), 'wonder');
      // Neither is the English version, so the lookup stays ambiguous.
      expect(await lookup('Wonder (English Version)'), isNull);
    });
  });
}
