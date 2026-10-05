import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/data/artist_top_track_resolver.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

const _key = (artistId: 'artist-1', name: 'Test Artist');

/// Deezer and Last.fm on.
const _allSources = IntegrationPolicy(lastFmVerified: true);

/// Last.fm only.
const _lastFmOnly = IntegrationPolicy(
  lastFmVerified: true,
  disabledKeys: {'deezer'},
);

class _FakeLastFmApiClient extends LastFmApiClient {
  new(this.tracks) : super(apiKey: 'fake');

  final List<LastFmArtistTopTrack> tracks;
  int? requestedLimit;
  int callCount = 0;

  @override
  Future<List<LastFmArtistTopTrack>> getArtistTopTracks({
    required String artist,
    int limit = 10,
  }) async {
    callCount++;
    requestedLimit = limit;
    return tracks.take(limit).toList(growable: false);
  }
}

class _FakeDeezerApiClient extends DeezerApiClient {
  new(this.top) : super(dio: Dio());

  final List<DeezerTrack> top;
  int artistSearches = 0;
  int topCalls = 0;

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
  }) async {
    artistSearches++;
    return const [DeezerArtist(id: 9, name: 'Test Artist', fanCount: 10)];
  }

  @override
  Future<List<DeezerTrack>> getArtistTopTracks(
    int artistId, {
    int limit = 50,
    CancelToken? cancelToken,
  }) async {
    topCalls++;
    return top.take(limit).toList(growable: false);
  }

  @override
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = 100,
    CancelToken? cancelToken,
  }) async => const [];
}

class _FakeSubsonicApiClient extends SubsonicApiClient {
  new({this.results = const {}})
    : super(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'user',
          password: 'pass',
          apiVersion: '1.16.1',
        ),
        enableLogging: false,
      );

  /// Songs returned for a query that starts with the key.
  final Map<String, List<Song>> results;

  /// When set, every search waits for it.
  Completer<void>? gate;
  final List<String> queries = <String>[];
  final List<CancelToken?> tokens = <CancelToken?>[];
  int activeSearchCalls = 0;
  int maxActiveSearchCalls = 0;

  int get searchCallCount => queries.length;

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
    tokens.add(cancelToken);
    activeSearchCalls++;
    if (activeSearchCalls > maxActiveSearchCalls) {
      maxActiveSearchCalls = activeSearchCalls;
    }
    try {
      if (gate case final gate?) {
        await gate.future;
      } else {
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      activeSearchCalls--;
    }
    for (final entry in results.entries) {
      if (query.startsWith('${entry.key} ')) {
        return SearchResult3(songs: entry.value);
      }
    }
    return const SearchResult3();
  }
}

class _FixtureDiagnosticsOverrides extends SyncDiagnosticsOverridesController {
  @override
  SyncDiagnosticsOverrides build() =>
      const SyncDiagnosticsOverrides(artistTopTracksPresentationFixture: true);
}

class _MutableLibrarySyncController extends LibrarySyncController {
  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  LibrarySyncState get value => state;

  set value(LibrarySyncState next) => state = next;
}

/// Zero-padded, so "Track 01" never contains "Track 10".
String _title(int rank) => 'Track ${rank.toString().padLeft(2, '0')}';

List<LastFmArtistTopTrack> _lastFmTracks(int count) => [
  for (var i = 0; i < count; i++)
    LastFmArtistTopTrack(
      rank: i + 1,
      title: _title(i + 1),
      artist: 'Test Artist',
    ),
];

List<DeezerTrack> _deezerTracks(int count) => [
  for (var i = 0; i < count; i++)
    DeezerTrack(
      id: 1000 + i,
      title: _title(i + 1),
      rank: 100000 - i,
      artist: const DeezerArtist(id: 9, name: 'Test Artist'),
    ),
];

SongsTableCompanion _librarySong(String id, String title) =>
    SongsTableCompanion.insert(
      id: id,
      title: title,
      artistName: const Value('Test Artist'),
      albumName: const Value('Local Album'),
      coverArt: Value('cover-$id'),
    );

void main() {
  late Directory cacheRoot;
  late DateTime now;

  setUp(() {
    cacheRoot = Directory.systemTemp.createTempSync('artist_top_tracks_test_');
    now = DateTime.now();
  });

  tearDown(() {
    if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
  });

  List<Override> sourceOverrides({
    IntegrationPolicy policy = _allSources,
    DeezerApiClient? deezer,
    LastFmApiClient? lastFm,
    SubsonicApiClient? subsonic,
  }) {
    // Captured now: a save still running when the test ends must not land
    // in the next test's directory.
    final root = cacheRoot;
    final jsonCache = IntegrationJsonCache(readRootDirectory: () async => root);
    return [
      integrationPolicyProvider.overrideWithValue(policy),
      integrationJsonCacheProvider.overrideWithValue(jsonCache),
      artistTopTrackMatchStoreProvider.overrideWithValue(
        ArtistTopTrackMatchStore(cache: jsonCache, now: () => now),
      ),
      deezerApiClientProvider.overrideWithValue(
        deezer ?? _FakeDeezerApiClient(const []),
      ),
      lastFmApiClientProvider.overrideWithValue(
        lastFm ?? _FakeLastFmApiClient(const []),
      ),
      subsonicApiProvider.overrideWithValue(subsonic),
    ];
  }

  NavisDatabase database() {
    final db = createTestDatabase();
    addTearDown(db.close);
    return db;
  }

  ProviderContainer containerWith(
    NavisDatabase db, {
    required List<Override> overrides,
  }) {
    final container = ProviderContainer(
      overrides: withTestDatabase(db, overrides: overrides),
    );
    addTearDown(container.dispose);
    return container;
  }

  /// The section's data emissions, once [count] have arrived.
  Future<List<List<ResolvedArtistTopTrack>>> sectionEmissions(
    ProviderContainer container, {
    required int count,
  }) async {
    final emissions = <List<ResolvedArtistTopTrack>>[];
    final done = Completer<void>();
    container.listen(artistTopTracksProvider(_key), (_, next) {
      if (next case AsyncData(:final value)) {
        emissions.add(value);
        if (emissions.length == count && !done.isCompleted) done.complete();
      }
    }, fireImmediately: true);
    await done.future.timeout(const Duration(seconds: 5));
    return emissions;
  }

  Future<List<ResolvedArtistTopTrack>> playlist(ProviderContainer container) {
    container.listen(artistTopTracksPlaylistProvider(_key), (_, _) {});
    return container.read(artistTopTracksPlaylistProvider(_key).future);
  }

  Future<List<ArtistTopTrackSeed>> seeds(ProviderContainer container) {
    container.listen(artistTopTrackSeedsProvider(_key), (_, _) {});
    return container.read(artistTopTrackSeedsProvider(_key).future);
  }

  group('sources', () {
    test('Last.fm is asked for up to 50 tracks', () async {
      final lastFm = _FakeLastFmApiClient(_lastFmTracks(12));
      final container = containerWith(
        database(),
        overrides: sourceOverrides(policy: _lastFmOnly, lastFm: lastFm),
      );

      final result = await seeds(container);

      expect(lastFm.requestedLimit, kArtistTopTracksPlaylistMax);
      expect(lastFm.callCount, 1);
      expect(result, hasLength(12));
      expect(result.first.source, ArtistTopTrackSource.lastFm);
    });

    test('Deezer comes first and its songs carry no listener count', () async {
      final deezer = _FakeDeezerApiClient(_deezerTracks(12));
      final lastFm = _FakeLastFmApiClient(_lastFmTracks(12));
      final container = containerWith(
        database(),
        overrides: sourceOverrides(deezer: deezer, lastFm: lastFm),
      );

      final result = await seeds(container);

      expect(deezer.topCalls, 1);
      expect(lastFm.callCount, 0);
      expect(result, hasLength(12));
      expect(result.every((seed) => seed.listeners == null), isTrue);
      expect(
        container
            .read(integrationCallRecorderProvider)
            .recentSpans()
            .single
            .counts,
        {'seeds': 12, 'cacheHit': 0, 'deezer': 1},
      );
    });

    test(
      'a Deezer artist id in the library id skips the artist search',
      () async {
        final deezer = _FakeDeezerApiClient(_deezerTracks(2));
        final container = containerWith(
          database(),
          overrides: sourceOverrides(deezer: deezer),
        );
        const key = (artistId: 'ext-deezer-artist-9', name: 'Test Artist');
        container.listen(artistTopTrackSeedsProvider(key), (_, _) {});

        await container.read(artistTopTrackSeedsProvider(key).future);

        expect(deezer.artistSearches, 0);
        expect(deezer.topCalls, 1);
      },
    );

    test(
      'clone-only presentation fixture bypasses sources and credentials',
      () async {
        final container = containerWith(
          database(),
          overrides: [
            ...sourceOverrides(policy: const IntegrationPolicy.denyAll()),
            syncDiagnosticsOverridesProvider.overrideWith(
              _FixtureDiagnosticsOverrides.new,
            ),
          ],
        );

        final result = await seeds(container);

        expect(result.map((seed) => seed.title), <String>[
          'North Star',
          'Afterglow',
          'Blue Hour',
          'Slow Motion',
        ]);
        expect(result.first.listeners, 482910);
      },
    );
  });

  group('integration gate', () {
    test('any one allowed source keeps top songs on', () {
      for (final entry in const <(IntegrationPolicy, bool)>[
        (_allSources, true),
        (_lastFmOnly, true),
        // Deezer needs no key.
        (IntegrationPolicy(), true),
        (
          IntegrationPolicy(
            lastFmVerified: true,
            disabledKeys: {'deezer.topSongs', 'lastfm.topSongs'},
          ),
          false,
        ),
        (IntegrationPolicy(disabledKeys: {'deezer'}), false),
        (IntegrationPolicy(lastFmVerified: true, masterEnabled: false), false),
      ]) {
        final (policy, allowed) = entry;
        final container = ProviderContainer(
          overrides: [integrationPolicyProvider.overrideWithValue(policy)],
        );
        addTearDown(container.dispose);
        expect(
          container.read(artistTopSongsAllowedProvider),
          allowed,
          reason:
              '${policy.disabledKeys} master=${policy.masterEnabled} '
              'lastFm=${policy.lastFmVerified}',
        );
      }
    });

    for (final entry in const <String, IntegrationPolicy>{
      'both top songs switches are off': IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'deezer.topSongs', 'lastfm.topSongs'},
      ),
      'both services are off': IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'deezer', 'lastfm'},
      ),
      'the master switch is off': IntegrationPolicy(
        lastFmVerified: true,
        masterEnabled: false,
      ),
    }.entries) {
      test('no request and no songs when ${entry.key}', () async {
        final deezer = _FakeDeezerApiClient(_deezerTracks(5));
        final lastFm = _FakeLastFmApiClient(_lastFmTracks(5));
        final container = containerWith(
          database(),
          overrides: sourceOverrides(
            policy: entry.value,
            deezer: deezer,
            lastFm: lastFm,
          ),
        );

        expect(await seeds(container), isEmpty);
        expect(container.read(artistTopSongsAllowedProvider), isFalse);
        expect(deezer.artistSearches + deezer.topCalls, 0);
        expect(lastFm.callCount, 0);
      });
    }

    test('a cached result is not served while the feature is off', () async {
      final lastFm = _FakeLastFmApiClient(_lastFmTracks(3));
      final db = database();
      final on = containerWith(
        db,
        overrides: sourceOverrides(policy: _lastFmOnly, lastFm: lastFm),
      );
      expect(await seeds(on), hasLength(3));

      final off = containerWith(
        db,
        overrides: sourceOverrides(
          policy: const IntegrationPolicy(
            lastFmVerified: true,
            masterEnabled: false,
          ),
          lastFm: lastFm,
        ),
      );
      expect(await seeds(off), isEmpty);
    });
  });

  group('resolution', () {
    test(
      'the section searches only its own unmatched songs, never all 50',
      () async {
        final db = database();
        await db.libraryDao.upsertSongs([
          _librarySong('local-1', 'Track 01'),
          _librarySong('local-2', 'Track 02'),
          _librarySong('local-3', 'Track 03'),
        ]);
        final deezer = _FakeDeezerApiClient(_deezerTracks(50));
        final subsonic = _FakeSubsonicApiClient();
        final container = containerWith(
          db,
          overrides: sourceOverrides(deezer: deezer, subsonic: subsonic),
        );

        final emissions = await sectionEmissions(container, count: 2);
        final tracks = emissions.last;

        expect(tracks, hasLength(kArtistTopTracksSectionMax));
        expect(tracks.last.rank, kArtistTopTracksSectionMax);
        expect(deezer.topCalls, 1);
        // Ten section songs, three in the library: seven searches, all of
        // them for section songs.
        expect(subsonic.searchCallCount, 7);
        expect(subsonic.queries.map((query) => query.split(' ')[1]).toSet(), {
          '04',
          '05',
          '06',
          '07',
          '08',
          '09',
          '10',
        });
        expect(
          subsonic.maxActiveSearchCalls,
          lessThanOrEqualTo(kArtistTopTrackSearchWorkers),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'the section emits local matches first, then the final result',
      () async {
        final db = database();
        await db.libraryDao.upsertSongs([_librarySong('local-1', 'Track 01')]);
        final subsonic = _FakeSubsonicApiClient(
          results: {
            'Track 02': const [
              Song(id: 'server-2', title: 'Track 02', artist: 'Test Artist'),
            ],
          },
        )..gate = Completer<void>();
        final container = containerWith(
          db,
          overrides: sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(3)),
            subsonic: subsonic,
          ),
        );

        final emissions = <List<ResolvedArtistTopTrack>>[];
        final firstEmission = Completer<void>();
        final finalEmission = Completer<void>();
        container.listen(artistTopTracksProvider(_key), (_, next) {
          if (next case AsyncData(:final value)) {
            emissions.add(value);
            if (emissions.length == 1) firstEmission.complete();
            if (emissions.length == 2) finalEmission.complete();
          }
        });

        await firstEmission.future.timeout(const Duration(seconds: 5));
        expect(
          emissions.single.map((track) => track.resolvedSong?.id),
          <String?>['local-1', null, null],
        );
        await pumpEventQueue();
        expect(subsonic.searchCallCount, 2);
        expect(emissions, hasLength(1));

        subsonic.gate!.complete();
        await finalEmission.future.timeout(const Duration(seconds: 5));
        expect(emissions.last.map((track) => track.resolvedSong?.id), <String?>[
          'local-1',
          'server-2',
          null,
        ]);
        expect(emissions, hasLength(2));
      },
      skip: !sqliteAvailable,
    );

    test(
      'leaving the artist page cancels the searches and starts no more',
      () async {
        final subsonic = _FakeSubsonicApiClient()..gate = Completer<void>();
        final container = containerWith(
          database(),
          overrides: sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(10)),
            subsonic: subsonic,
          ),
        );

        container.listen(artistTopTracksProvider(_key), (_, _) {});
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (subsonic.searchCallCount < kArtistTopTrackSearchWorkers &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await pumpEventQueue();
        expect(subsonic.searchCallCount, kArtistTopTrackSearchWorkers);

        container.dispose();
        expect(subsonic.tokens, everyElement(isNotNull));
        expect(subsonic.tokens.every((token) => token!.isCancelled), isTrue);

        subsonic.gate!.complete();
        await pumpEventQueue();
        expect(subsonic.searchCallCount, kArtistTopTrackSearchWorkers);
      },
      skip: !sqliteAvailable,
    );

    test(
      'a Deezer track held as ext-deezer-song is matched without a search',
      () async {
        final db = database();
        await db.libraryDao.upsertSongs([
          _librarySong('ext-deezer-song-1000', 'Renamed In Library'),
        ]);
        final subsonic = _FakeSubsonicApiClient();
        final container = containerWith(
          db,
          overrides: sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(1)),
            subsonic: subsonic,
          ),
        );

        final emissions = await sectionEmissions(container, count: 1);

        expect(
          emissions.single.single.resolvedSong?.id,
          'ext-deezer-song-1000',
        );
        expect(subsonic.searchCallCount, 0);
      },
      skip: !sqliteAvailable,
    );

    test(
      'reopening an artist reuses remembered matches without searching',
      () async {
        final db = database();
        await db.libraryDao.upsertSongs([_librarySong('local-1', 'Track 01')]);
        const remote = Song(
          id: 'ext-deezer-song-77',
          title: 'Track 02',
          artist: 'Test Artist',
          isExternal: true,
        );
        final firstSubsonic = _FakeSubsonicApiClient(
          results: {
            'Track 02': const [remote],
          },
        );
        final first = containerWith(
          db,
          overrides: sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(3)),
            subsonic: firstSubsonic,
          ),
        );
        await sectionEmissions(first, count: 2);
        expect(firstSubsonic.searchCallCount, 2);
        await first.read(artistTopTrackMatchStoreProvider).whenSaved();
        first.dispose();

        final secondSubsonic = _FakeSubsonicApiClient();
        final second = containerWith(
          db,
          overrides: sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(3)),
            subsonic: secondSubsonic,
          ),
        );
        final emissions = await sectionEmissions(second, count: 1);

        expect(secondSubsonic.searchCallCount, 0);
        expect(
          emissions.single.map((track) => track.resolvedSong?.id),
          <String?>['local-1', 'ext-deezer-song-77', null],
        );
        final localSpan = second
            .read(integrationCallRecorderProvider)
            .recentSpans()
            .firstWhere((span) => span.name == 'topSongs.localMatch');
        // The library song comes from memory; the remote and unmatched ones
        // are checked against the library again, then taken from memory.
        expect(localSpan.counts['cached'], 3);
        expect(localSpan.counts['localHits'], 0);
      },
      skip: !sqliteAvailable,
    );

    test('remembered unmatched songs are searched again after a day', () async {
      final db = database();
      final first = containerWith(
        db,
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(2)),
          subsonic: _FakeSubsonicApiClient(),
        ),
      );
      await sectionEmissions(first, count: 1);
      await first.read(artistTopTrackMatchStoreProvider).whenSaved();
      first.dispose();

      final soon = _FakeSubsonicApiClient();
      final second = containerWith(
        db,
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(2)),
          subsonic: soon,
        ),
      );
      await sectionEmissions(second, count: 1);
      expect(soon.searchCallCount, 0);
      second.dispose();

      now = now.add(const Duration(hours: 25));
      final later = _FakeSubsonicApiClient();
      final third = containerWith(
        db,
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(2)),
          subsonic: later,
        ),
      );
      await sectionEmissions(third, count: 1);
      expect(later.searchCallCount, 2);
    }, skip: !sqliteAvailable);

    test('a remembered library song that is gone is searched again', () async {
      final db = database();
      await db.libraryDao.upsertSongs([_librarySong('local-1', 'Track 01')]);
      final first = containerWith(
        db,
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(1)),
          subsonic: _FakeSubsonicApiClient(),
        ),
      );
      await sectionEmissions(first, count: 1);
      await first.read(artistTopTrackMatchStoreProvider).whenSaved();
      first.dispose();

      await db.customStatement("DELETE FROM songs WHERE id = 'local-1'");
      final subsonic = _FakeSubsonicApiClient();
      final second = containerWith(
        db,
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(1)),
          subsonic: subsonic,
        ),
      );
      final emissions = await sectionEmissions(second, count: 1);

      expect(subsonic.searchCallCount, 1);
      // Nothing local to show first: one emission, after the search.
      expect(emissions, hasLength(1));
      expect(emissions.single.single.resolvedSong, isNull);
    }, skip: !sqliteAvailable);

    test('a finished library sync forgets remembered matches', () async {
      final controller = _MutableLibrarySyncController();
      final subsonic = _FakeSubsonicApiClient();
      final container = containerWith(
        database(),
        overrides: [
          ...sourceOverrides(
            deezer: _FakeDeezerApiClient(_deezerTracks(2)),
            subsonic: subsonic,
          ),
          librarySyncControllerProvider.overrideWith(() => controller),
        ],
      );
      container.read(artistTopTrackMatchSyncBridgeProvider);
      final store = container.read(artistTopTrackMatchStoreProvider);
      await sectionEmissions(container, count: 1);
      await store.whenSaved();
      expect(await store.load(_key.artistId), hasLength(2));
      expect(subsonic.searchCallCount, 2);

      controller.value = const LibrarySyncState(
        status: LibrarySyncStatus.running,
        stage: LibrarySyncStage.idle,
      );
      await pumpEventQueue();
      expect(subsonic.searchCallCount, 2);

      // The section is still open: it matches again against the synced
      // library, and the forgotten unmatched songs are searched again.
      controller.value = const LibrarySyncState(
        status: LibrarySyncStatus.partial,
        stage: LibrarySyncStage.idle,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (subsonic.searchCallCount < 4 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(subsonic.searchCallCount, 4);
    }, skip: !sqliteAvailable);

    test('the playlist resolves all 50 songs', () async {
      final subsonic = _FakeSubsonicApiClient();
      final container = containerWith(
        database(),
        overrides: sourceOverrides(
          deezer: _FakeDeezerApiClient(_deezerTracks(50)),
          subsonic: subsonic,
        ),
      );

      final tracks = await playlist(container);

      expect(tracks, hasLength(50));
      expect(tracks.first.rank, 1);
      expect(tracks.last.rank, 50);
      expect(subsonic.searchCallCount, 50);
    }, skip: !sqliteAvailable);

    test(
      'section and playlist at once share the searches they overlap on',
      () async {
        final subsonic = _FakeSubsonicApiClient()..gate = Completer<void>();
        final deezer = _FakeDeezerApiClient(_deezerTracks(12));
        final container = containerWith(
          database(),
          overrides: sourceOverrides(deezer: deezer, subsonic: subsonic),
        );

        final section = sectionEmissions(container, count: 1);
        final all = playlist(container);
        await pumpEventQueue();
        subsonic.gate!.complete();
        final sectionResult = await section;
        final playlistResult = await all;

        expect(sectionResult.last, hasLength(10));
        expect(playlistResult, hasLength(12));
        expect(deezer.topCalls, 1);
        expect(subsonic.searchCallCount, 12);
      },
      skip: !sqliteAvailable,
    );

    test(
      'records spans for the source fetch, local match and server match',
      () async {
        final db = database();
        await db.libraryDao.upsertSongs([_librarySong('local-1', 'Track 01')]);
        final container = containerWith(
          db,
          overrides: sourceOverrides(
            policy: _lastFmOnly,
            lastFm: _FakeLastFmApiClient(_lastFmTracks(3)),
            subsonic: _FakeSubsonicApiClient(),
          ),
        );

        await sectionEmissions(container, count: 2);

        final spans = {
          for (final span
              in container.read(integrationCallRecorderProvider).recentSpans())
            span.name: span.counts,
        };
        expect(spans.keys, <String>[
          'topSongs.sourceFetch',
          'topSongs.localMatch',
          'topSongs.serverMatch',
        ]);
        expect(spans['topSongs.sourceFetch'], {
          'seeds': 3,
          'cacheHit': 0,
          'deezer': 0,
        });
        expect(spans['topSongs.localMatch'], {
          'seeds': 3,
          'cached': 0,
          'candidates': 1,
          'localHits': 1,
        });
        expect(spans['topSongs.serverMatch'], {
          'unresolved': 2,
          'search3Calls': 2,
          'matched': 0,
          'remote': 0,
        });
      },
      skip: !sqliteAvailable,
    );

    test('no songs leave the section and the playlist empty', () async {
      final container = containerWith(
        database(),
        overrides: sourceOverrides(subsonic: _FakeSubsonicApiClient()),
      );

      final section = await sectionEmissions(container, count: 1);
      final all = await playlist(container);

      expect(section.single, isEmpty);
      expect(all, isEmpty);
    }, skip: !sqliteAvailable);
  });

  // ---------------------------------------------------------------------------
  // Matching of search3 results
  // ---------------------------------------------------------------------------

  Song song({
    String id = '1',
    required String title,
    String? artist,
    String? album,
  }) => Song(id: id, title: title, artist: artist, album: album);

  TrackMatchQuery query({required String title, required String artist}) =>
      TrackMatchQuery(title: title, artist: artist);

  test('selects exact match from candidates', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen'),
        song(id: '2', title: 'We Will Rock You', artist: 'Queen'),
      ],
    );

    expect(match?.id, '1');
  });

  test('selects correct song when multiple artists have same title', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'RUNAWAY', artist: 'Aurora'),
      candidates: [
        song(id: '1', title: 'Runaway', artist: 'Kanye West'),
        song(id: '2', title: 'Runaway', artist: 'Aurora'),
        song(id: '3', title: 'Runaway', artist: 'Bon Jovi'),
      ],
    );

    expect(match?.id, '2');
  });

  test('returns null when no candidate exceeds minimum score', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(
          id: '1',
          title: 'Completely Different Song',
          artist: 'Unknown Band',
        ),
      ],
    );

    expect(match, isNull);
  });

  test('returns null when title matches exactly but artist is completely different', () {
    // "Heart Attack" by Demi Lovato should NOT match a search for a
    // "Heart Attack" track by Pokelawls — the artist is entirely wrong.
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Heart Attack', artist: 'Pokelawls'),
      candidates: [song(id: '1', title: 'Heart Attack', artist: 'Demi Lovato')],
    );

    expect(match, isNull);
  });

  test('returns null when title partially matches but artist is completely different', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'RUNWAY', artist: 'Pokelawls'),
      candidates: [song(id: '1', title: 'RUNAWAY', artist: 'Aurora')],
    );

    expect(match, isNull);
  });

  test('returns null for empty candidate list', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [],
    );

    expect(match, isNull);
  });

  test('prefers studio version over live recording', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(id: 'live', title: 'Bohemian Rhapsody (Live)', artist: 'Queen'),
        song(id: 'studio', title: 'Bohemian Rhapsody', artist: 'Queen'),
      ],
    );

    expect(match?.id, 'studio');
  });

  test('penalises songs on live albums', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(
          id: 'live-album',
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
          album: 'Live at Wembley',
        ),
        song(
          id: 'studio',
          title: 'Bohemian Rhapsody',
          artist: 'Queen',
          album: 'A Night at the Opera',
        ),
      ],
    );

    expect(match?.id, 'studio');
  });

  test('matches despite parenthetical differences', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Blinding Lights', artist: 'The Weeknd'),
      candidates: [
        song(
          id: '1',
          title: 'Blinding Lights (Official Audio)',
          artist: 'The Weeknd',
        ),
      ],
    );

    expect(match?.id, '1');
  });

  test('matches despite feat. in title', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'Locked Out of Heaven', artist: 'Bruno Mars'),
      candidates: [
        song(
          id: '1',
          title: 'Locked Out of Heaven (feat. Someone)',
          artist: 'Bruno Mars',
        ),
      ],
    );

    expect(match?.id, '1');
  });

  test('matches case-insensitively', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: 'bohemian rhapsody', artist: 'queen'),
      candidates: [song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen')],
    );

    expect(match?.id, '1');
  });

  test('matches when punctuation differs', () {
    final match = pickBestArtistTopTrackMatch(
      track: query(title: "Don't Stop Me Now", artist: 'Queen'),
      candidates: [song(id: '1', title: 'Dont Stop Me Now', artist: 'Queen')],
    );

    expect(match?.id, '1');
  });
}
