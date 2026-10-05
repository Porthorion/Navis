import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/data/artist_top_track_resolver.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';

import '../../../../helpers/test_database.dart';

/// Answers `search3` with [results] for a query starting with the key, or
/// fails for a key in [failing]; optionally holds every search at [gate].
class _FakeSubsonic extends SubsonicApiClient {
  new()
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'user',
          password: 'pass',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  final Map<String, List<Song>> results = <String, List<Song>>{};
  final Set<String> failing = <String>{};
  final List<String> queries = <String>[];
  Completer<void>? gate;

  @override
  Future<SearchResult3> search3({
    required String query,
    int artistCount = 20,
    int albumCount = 20,
    int songCount = 20,
    int artistOffset = 0,
    int albumOffset = 0,
    int songOffset = 0,
    CancelToken? cancelToken,
  }) async {
    queries.add(query);
    await (gate?.future ?? Future<void>.delayed(Duration.zero));
    for (final key in failing) {
      if (query.startsWith('$key ')) throw StateError('search failed');
    }
    for (final MapEntry(:key, :value) in results.entries) {
      if (query.startsWith('$key ')) return SearchResult3(songs: value);
    }
    return const SearchResult3();
  }
}

ArtistTopTrackSeed _seed(int rank, String title, {String artist = 'Known'}) =>
    ArtistTopTrackSeed(
      rank: rank,
      title: title,
      artist: artist,
      source: ArtistTopTrackSource.deezer,
    );

Song _remote(String title, {String artist = 'Known', int id = 1}) => Song(
  id: 'ext-deezer-song-$id',
  title: title,
  artist: artist,
  artistId: 'ext-deezer-artist-$id',
  album: 'Remote Album',
  albumId: 'ext-deezer-album-$id',
  isExternal: true,
);

Song _server(String title, {String artist = 'Known'}) => Song(
  id: 'server-$title',
  title: title,
  artist: artist,
  artistId: 'artist-known',
  album: 'Server Album',
  albumId: 'album-server',
  isExternal: false,
);

void main() {
  late Directory cacheRoot;
  late DateTime now;
  late NavisDatabase db;
  late _FakeSubsonic api;
  late ArtistTopTrackMatchStore store;

  setUp(() {
    cacheRoot = Directory.systemTemp.createTempSync('top_track_resolver_');
    now = DateTime.now();
    db = createTestDatabase();
    api = _FakeSubsonic();
    final root = cacheRoot;
    // A store that keeps entries for a week, like Trending's.
    store = ArtistTopTrackMatchStore(
      cache: IntegrationJsonCache(readRootDirectory: () async => root),
      namespace: 'test.matches',
      keepFor: const Duration(days: 7),
      now: () => now,
    );
  });

  tearDown(() async {
    await store.whenSaved();
    await db.close();
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  ArtistTopTrackResolver resolver({IntegrationCallRecorder? recorder}) =>
      ArtistTopTrackResolver(
        libraryDao: db.libraryDao,
        api: api,
        store: store,
        recorder: recorder ?? IntegrationCallRecorder(),
      );

  Future<List<List<ResolvedArtistTopTrack>>> emissions(
    ArtistTopTrackResolver resolver,
    List<ArtistTopTrackSeed> seeds, {
    bool researchUnmatched = false,
    bool yieldPendingRows = false,
    int? progressEvery,
    int searchWorkers = 4,
  }) async {
    final result = await resolver
        .resolve(
          artistId: 'list',
          seeds: seeds,
          cancelToken: CancelToken(),
          researchUnmatched: researchUnmatched,
          yieldPendingRows: yieldPendingRows,
          progressEvery: progressEvery,
          searchWorkers: searchWorkers,
        )
        .toList();
    await store.whenSaved();
    return result;
  }

  test(
    'a copy on the server wins over a remote result and is stored',
    () async {
      api.results['Alpha'] = <Song>[_remote('Alpha'), _server('Alpha')];

      final first = await emissions(resolver(), <ArtistTopTrackSeed>[
        _seed(1, 'Alpha'),
      ]);
      expect(first.last.single.resolvedSong?.id, 'server-Alpha');
      // Stored as a provisional row, so the next pass finds it locally.
      final row = await db.libraryDao.getSongById('server-Alpha');
      expect(row?.isProvisional, isTrue);

      api.queries.clear();
      final second = await emissions(resolver(), <ArtistTopTrackSeed>[
        _seed(1, 'Alpha'),
      ]);
      expect(second.single.single.resolvedSong?.id, 'server-Alpha');
      expect(api.queries, isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test('a remote match is kept when no server copy exists', () async {
    api.results['Alpha'] = <Song>[_remote('Alpha')];
    final first = await emissions(resolver(), <ArtistTopTrackSeed>[
      _seed(1, 'Alpha'),
    ]);
    expect(first.last.single.resolvedSong?.id, 'ext-deezer-song-1');
    // Remote songs are not stored in the library.
    expect(await db.libraryDao.getSongById('ext-deezer-song-1'), isNull);
  }, skip: !sqliteAvailable);

  group('a remembered remote match older than a day', () {
    setUp(() async {
      api.results['Alpha'] = <Song>[_remote('Alpha')];
      await emissions(resolver(), <ArtistTopTrackSeed>[_seed(1, 'Alpha')]);
      api.queries.clear();
      now = now.add(const Duration(hours: 25));
    });

    test('is never replaced by another remote result', () async {
      api.results['Alpha'] = <Song>[_remote('Alpha', id: 2)];
      final recorder = IntegrationCallRecorder();
      final result = await emissions(
        resolver(recorder: recorder),
        <ArtistTopTrackSeed>[_seed(1, 'Alpha')],
      );
      expect(api.queries, hasLength(1));
      // The remote song shows while the server is checked, and stays.
      expect(result.first.single.resolvedSong?.id, 'ext-deezer-song-1');
      expect(result.first.single.isMatching, isFalse);
      expect(result.last.single.resolvedSong?.id, 'ext-deezer-song-1');
      final span = recorder.recentSpans().lastWhere(
        (span) => span.name == 'topSongs.serverMatch',
      );
      expect(span.counts['upgradeChecks'], 1);
      expect(span.counts['upgraded'], 0);

      // Remembered as remote again: no search for another day.
      api.queries.clear();
      final next = await emissions(resolver(), <ArtistTopTrackSeed>[
        _seed(1, 'Alpha'),
      ]);
      expect(api.queries, isEmpty);
      expect(next.single.single.resolvedSong?.id, 'ext-deezer-song-1');
    }, skip: !sqliteAvailable);

    test('survives a failed search', () async {
      api.failing.add('Alpha');
      final result = await emissions(resolver(), <ArtistTopTrackSeed>[
        _seed(1, 'Alpha'),
      ]);
      expect(result.last.single.resolvedSong?.id, 'ext-deezer-song-1');
      // Not marked checked: the next resolve searches again.
      api
        ..failing.clear()
        ..queries.clear();
      await emissions(resolver(), <ArtistTopTrackSeed>[_seed(1, 'Alpha')]);
      expect(api.queries, hasLength(1));
    }, skip: !sqliteAvailable);

    test('switches to a copy on the server', () async {
      api.results['Alpha'] = <Song>[_remote('Alpha'), _server('Alpha')];
      final recorder = IntegrationCallRecorder();
      final result = await emissions(
        resolver(recorder: recorder),
        <ArtistTopTrackSeed>[_seed(1, 'Alpha')],
      );
      expect(result.last.single.resolvedSong?.id, 'server-Alpha');
      final span = recorder.recentSpans().lastWhere(
        (span) => span.name == 'topSongs.serverMatch',
      );
      expect(span.counts['upgraded'], 1);
    }, skip: !sqliteAvailable);
  });

  test(
    'unmatched songs wait a day, unless a manual refresh asks again',
    () async {
      final seeds = <ArtistTopTrackSeed>[_seed(1, 'Alpha')];
      final shared = resolver();
      await emissions(shared, seeds);
      expect(api.queries, hasLength(1));

      await emissions(shared, seeds);
      expect(api.queries, hasLength(1));

      // A manual refresh searches again, even with this session's earlier
      // search still fresh.
      api.results['Alpha'] = <Song>[_remote('Alpha')];
      final refreshed = await emissions(shared, seeds, researchUnmatched: true);
      expect(api.queries, hasLength(2));
      expect(refreshed.last.single.resolvedSong?.id, 'ext-deezer-song-1');

      now = now.add(const Duration(hours: 25));
      api.results.remove('Alpha');
      await emissions(resolver(), <ArtistTopTrackSeed>[_seed(2, 'Bravo')]);
      expect(api.queries, hasLength(3));
    },
    skip: !sqliteAvailable,
  );

  test('pending rows show first and progress arrives in batches', () async {
    await db.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'lib-Alpha',
        title: 'Alpha',
        artistName: const Value('Known'),
      ),
    ]);
    final seeds = <ArtistTopTrackSeed>[
      _seed(1, 'Alpha'),
      _seed(2, 'Bravo'),
      _seed(3, 'Charlie'),
      _seed(4, 'Delta'),
      _seed(5, 'Echo'),
    ];
    api.results['Bravo'] = <Song>[_remote('Bravo', id: 2)];

    final result = await emissions(
      resolver(),
      seeds,
      yieldPendingRows: true,
      progressEvery: 2,
      searchWorkers: 1,
    );

    // The local pass: Alpha from the library, the rest still matching.
    expect(result.first.map((track) => track.isMatching), <bool>[
      false,
      true,
      true,
      true,
      true,
    ]);
    expect(result.first.first.resolvedSong?.id, 'lib-Alpha');
    // After two searches, then the end.
    expect(result, hasLength(3));
    expect(result[1].map((track) => track.isMatching), <bool>[
      false,
      false,
      false,
      true,
      true,
    ]);
    expect(result[1][1].resolvedSong?.id, 'ext-deezer-song-2');
    expect(result.last.any((track) => track.isMatching), isFalse);
    expect(result.last.map((track) => track.rank), <int>[1, 2, 3, 4, 5]);
  }, skip: !sqliteAvailable);

  test('nothing local: pending rows only when asked for', () async {
    final seeds = <ArtistTopTrackSeed>[_seed(1, 'Alpha')];
    final quiet = await emissions(resolver(), seeds);
    expect(quiet, hasLength(1));
    expect(quiet.single.single.isMatching, isFalse);

    final pending = await emissions(resolver(), <ArtistTopTrackSeed>[
      _seed(2, 'Bravo'),
    ], yieldPendingRows: true);
    expect(pending, hasLength(2));
    expect(pending.first.single.isMatching, isTrue);
    expect(pending.last.single.isMatching, isFalse);
  }, skip: !sqliteAvailable);

  test('the default store forgets a remote match after a day', () async {
    final root = cacheRoot;
    store = ArtistTopTrackMatchStore(
      cache: IntegrationJsonCache(readRootDirectory: () async => root),
      now: () => now,
    );
    api.results['Alpha'] = <Song>[_remote('Alpha')];
    await emissions(resolver(), <ArtistTopTrackSeed>[_seed(1, 'Alpha')]);
    now = now.add(const Duration(hours: 25));
    expect(await store.load('list'), isEmpty);
  }, skip: !sqliteAvailable);
}
