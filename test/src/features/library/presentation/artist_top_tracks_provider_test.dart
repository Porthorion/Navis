import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';
import 'package:riverpod/src/framework.dart' show Override;

import '../../../../helpers/test_database.dart';

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

class _FakeSubsonicApiClient extends SubsonicApiClient {
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

  int searchCallCount = 0;
  int activeSearchCalls = 0;
  int maxActiveSearchCalls = 0;

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
    searchCallCount++;
    activeSearchCalls++;
    maxActiveSearchCalls = activeSearchCalls > maxActiveSearchCalls
        ? activeSearchCalls
        : maxActiveSearchCalls;
    await Future<void>.delayed(Duration.zero);
    activeSearchCalls--;
    return const SearchResult3();
  }
}

class _FixtureDiagnosticsOverrides extends SyncDiagnosticsOverridesController {
  @override
  SyncDiagnosticsOverrides build() =>
      const SyncDiagnosticsOverrides(artistTopTracksPresentationFixture: true);
}

List<LastFmArtistTopTrack> _lastFmTracks(int count) {
  return List<LastFmArtistTopTrack>.generate(
    count,
    (index) => LastFmArtistTopTrack(
      rank: index + 1,
      title: 'Track ${index + 1}',
      artist: 'Test Artist',
    ),
  );
}

ProviderContainer _providerContainerWithDatabase({
  required List<Override> overrides,
}) {
  final db = createTestDatabase();
  final container = ProviderContainer(
    overrides: withTestDatabase(db, overrides: overrides),
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('artist_top_tracks_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (methodCall) async {
            if (methodCall.method == 'getApplicationSupportDirectory') {
              return tempDir.path;
            }
            return null;
          },
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  // ---------------------------------------------------------------------------
  // Helper to build a Song with minimal required fields.
  // ---------------------------------------------------------------------------
  Song song({
    String id = '1',
    required String title,
    String? artist,
    String? album,
  }) => Song(id: id, title: title, artist: artist, album: album);

  LastFmArtistTopTrack lastFm({
    required String title,
    required String artist,
    int rank = 1,
  }) => LastFmArtistTopTrack(rank: rank, title: title, artist: artist);

  test('raw provider requests up to 50 tracks from Last.fm', () async {
    final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(12));
    final container = ProviderContainer(
      overrides: [
        hasLastFmApiKeyProvider.overrideWithValue(true),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        lastFmApiClientProvider.overrideWithValue(fakeLastFm),
      ],
    );
    addTearDown(container.dispose);

    final tracks = await container.read(
      artistTopTracksRawProvider('Test Artist').future,
    );

    expect(fakeLastFm.requestedLimit, kArtistTopTracksPlaylistMax);
    expect(fakeLastFm.callCount, 1);
    expect(tracks, hasLength(12));
  });

  test(
    'clone-only presentation fixture bypasses Last.fm credentials',
    () async {
      final container = ProviderContainer(
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(false),
          syncDiagnosticsOverridesProvider.overrideWith(
            _FixtureDiagnosticsOverrides.new,
          ),
        ],
      );
      addTearDown(container.dispose);

      final tracks = await container.read(
        artistTopTracksRawProvider('Any Artist').future,
      );

      expect(tracks.map((track) => track.title), <String>[
        'North Star',
        'Afterglow',
        'Blue Hour',
        'Slow Motion',
      ]);
    },
  );

  test(
    'raw provider is shared by section and virtual playlist providers',
    () async {
      final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(12));
      final container = _providerContainerWithDatabase(
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(true),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          subsonicApiProvider.overrideWithValue(null),
        ],
      );

      final results = await Future.wait([
        container.read(artistTopTracksProvider('Test Artist').future),
        container.read(artistTopTracksPlaylistProvider('Test Artist').future),
      ]);

      expect(fakeLastFm.callCount, 1);
      expect(
        results[0].map((track) => track.rank),
        orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
      );
      expect(
        results[1].map((track) => track.rank),
        orderedEquals([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
      );
    },
  );

  test('section provider resolves only the first 10 raw top tracks', () async {
    final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(12));
    final container = _providerContainerWithDatabase(
      overrides: [
        hasLastFmApiKeyProvider.overrideWithValue(true),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        lastFmApiClientProvider.overrideWithValue(fakeLastFm),
        subsonicApiProvider.overrideWithValue(null),
      ],
    );

    final tracks = await container.read(
      artistTopTracksProvider('Test Artist').future,
    );

    expect(tracks, hasLength(kArtistTopTracksSectionMax));
    expect(tracks.last.rank, 10);
  });

  test('playlist provider resolves ranks 1 through 50', () async {
    final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(50));
    final container = _providerContainerWithDatabase(
      overrides: [
        hasLastFmApiKeyProvider.overrideWithValue(true),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        lastFmApiClientProvider.overrideWithValue(fakeLastFm),
        subsonicApiProvider.overrideWithValue(null),
      ],
    );

    final tracks = await container.read(
      artistTopTracksPlaylistProvider('Test Artist').future,
    );

    expect(tracks, hasLength(50));
    expect(tracks.first.rank, 1);
    expect(tracks.last.rank, 50);
  });

  test(
    'playlist provider does not pad when fewer than 10 raw tracks exist',
    () async {
      final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(8));
      final container = _providerContainerWithDatabase(
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(true),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          subsonicApiProvider.overrideWithValue(null),
        ],
      );

      final tracks = await container.read(
        artistTopTracksPlaylistProvider('Test Artist').future,
      );

      expect(tracks, hasLength(8));
      expect(tracks.first.rank, 1);
      expect(tracks.last.rank, 8);
    },
  );

  test('local snapshot exact match resolves without search3', () async {
    final db = createTestDatabase();
    addTearDown(db.close);
    await db.libraryDao.upsertSongs([
      SongsTableCompanion.insert(
        id: 'local-11',
        title: 'Track 11',
        artistName: const Value('Test Artist'),
        albumName: const Value('Local Album'),
        coverArt: const Value('cover-11'),
      ),
    ]);

    final fakeLastFm = _FakeLastFmApiClient([
      const LastFmArtistTopTrack(
        rank: 11,
        title: 'Track 11',
        artist: 'Test Artist',
      ),
    ]);
    final fakeSubsonic = _FakeSubsonicApiClient();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        db,
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(true),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          subsonicApiProvider.overrideWithValue(fakeSubsonic),
        ],
      ),
    );
    addTearDown(container.dispose);

    final tracks = await container.read(
      artistTopTracksPlaylistProvider('Test Artist').future,
    );

    expect(tracks, hasLength(1));
    expect(tracks.single.rank, 11);
    expect(tracks.single.resolvedSong?.id, 'local-11');
    expect(fakeSubsonic.searchCallCount, 0);
  }, skip: !sqliteAvailable);

  group('integration gate', () {
    for (final entry in const <String, IntegrationPolicy>{
      'the top songs switch is off': IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'lastfm.topSongs'},
      ),
      'the Last.fm service is off': IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'lastfm'},
      ),
      'the master switch is off': IntegrationPolicy(
        lastFmVerified: true,
        masterEnabled: false,
      ),
      'no key is verified': IntegrationPolicy(),
    }.entries) {
      test('no Last.fm request and no section when ${entry.key}', () async {
        final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(12));
        final container = ProviderContainer(
          overrides: [
            integrationPolicyProvider.overrideWithValue(entry.value),
            lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(artistTopSongsAllowedProvider), isFalse);
        final tracks = await container.read(
          artistTopTracksRawProvider('Test Artist').future,
        );

        expect(tracks, isEmpty);
        expect(fakeLastFm.callCount, 0);
      });
    }

    test('a cached result is not served while the feature is off', () async {
      final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(3));
      final on = ProviderContainer(
        overrides: [
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
        ],
      );
      addTearDown(on.dispose);
      expect(
        await on.read(artistTopTracksRawProvider('Test Artist').future),
        hasLength(3),
      );

      final off = ProviderContainer(
        overrides: [
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true, masterEnabled: false),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
        ],
      );
      addTearDown(off.dispose);
      expect(
        await off.read(artistTopTracksRawProvider('Test Artist').future),
        isEmpty,
      );
    });
  });

  test(
    'records timing spans for source fetch, local match and server match',
    () async {
      final db = createTestDatabase();
      addTearDown(db.close);
      await db.libraryDao.upsertSongs([
        SongsTableCompanion.insert(
          id: 'local-1',
          title: 'Track 1',
          artistName: const Value('Test Artist'),
          albumName: const Value('Local Album'),
        ),
      ]);
      final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(3));
      final fakeSubsonic = _FakeSubsonicApiClient();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [
            integrationPolicyProvider.overrideWithValue(
              const IntegrationPolicy(lastFmVerified: true),
            ),
            lastFmApiClientProvider.overrideWithValue(fakeLastFm),
            subsonicApiProvider.overrideWithValue(fakeSubsonic),
          ],
        ),
      );
      addTearDown(container.dispose);

      await container.read(
        artistTopTracksPlaylistProvider('Test Artist').future,
      );

      final spans = {
        for (final span
            in container.read(integrationCallRecorderProvider).recentSpans())
          span.name: span,
      };
      expect(spans.keys, <String>[
        'topSongs.sourceFetch',
        'topSongs.localMatch',
        'topSongs.serverMatch',
      ]);
      expect(spans['topSongs.sourceFetch']!.counts, {
        'tracks': 3,
        'cacheHit': 0,
      });
      expect(spans['topSongs.localMatch']!.counts, {
        'tracks': 3,
        'candidates': 1,
        'matched': 1,
      });
      expect(spans['topSongs.serverMatch']!.counts, {
        'unresolved': 2,
        'searches': 2,
        'matched': 0,
      });

      // A second load is served from the disk cache: the source span says so.
      final second = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [
            integrationPolicyProvider.overrideWithValue(
              const IntegrationPolicy(lastFmVerified: true),
            ),
            lastFmApiClientProvider.overrideWithValue(fakeLastFm),
            subsonicApiProvider.overrideWithValue(fakeSubsonic),
          ],
        ),
      );
      addTearDown(second.dispose);
      await second.read(artistTopTracksRawProvider('Test Artist').future);
      expect(
        second
            .read(integrationCallRecorderProvider)
            .recentSpans()
            .single
            .counts,
        {'tracks': 3, 'cacheHit': 1},
      );
      expect(fakeLastFm.callCount, 1);
    },
    skip: !sqliteAvailable,
  );

  test('search3 runs only for local misses with bounded concurrency', () async {
    final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(16));
    final fakeSubsonic = _FakeSubsonicApiClient();
    final container = _providerContainerWithDatabase(
      overrides: [
        hasLastFmApiKeyProvider.overrideWithValue(true),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        lastFmApiClientProvider.overrideWithValue(fakeLastFm),
        subsonicApiProvider.overrideWithValue(fakeSubsonic),
      ],
    );

    final tracks = await container.read(
      artistTopTracksPlaylistProvider('Test Artist').future,
    );

    expect(tracks, hasLength(16));
    expect(fakeSubsonic.searchCallCount, 16);
    expect(fakeSubsonic.maxActiveSearchCalls, lessThanOrEqualTo(4));
    expect(tracks.where((track) => track.resolvedSong == null), hasLength(16));
  }, skip: !sqliteAvailable);

  test(
    'watching section and playlist shares search3 resolution for overlap',
    () async {
      final fakeLastFm = _FakeLastFmApiClient(_lastFmTracks(12));
      final fakeSubsonic = _FakeSubsonicApiClient();
      final container = _providerContainerWithDatabase(
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(true),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          subsonicApiProvider.overrideWithValue(fakeSubsonic),
        ],
      );

      final results = await Future.wait([
        container.read(artistTopTracksProvider('Test Artist').future),
        container.read(artistTopTracksPlaylistProvider('Test Artist').future),
      ]);

      expect(results[0], hasLength(10));
      expect(results[1], hasLength(12));
      expect(fakeLastFm.callCount, 1);
      expect(fakeSubsonic.searchCallCount, 12);
    },
    skip: !sqliteAvailable,
  );

  test(
    'empty raw response leaves section and playlist providers empty',
    () async {
      final fakeLastFm = _FakeLastFmApiClient(const <LastFmArtistTopTrack>[]);
      final container = _providerContainerWithDatabase(
        overrides: [
          hasLastFmApiKeyProvider.overrideWithValue(true),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          lastFmApiClientProvider.overrideWithValue(fakeLastFm),
          subsonicApiProvider.overrideWithValue(null),
        ],
      );

      final section = await container.read(
        artistTopTracksProvider('Test Artist').future,
      );
      final playlist = await container.read(
        artistTopTracksPlaylistProvider('Test Artist').future,
      );

      expect(section, isEmpty);
      expect(playlist, isEmpty);
    },
  );

  // ---------------------------------------------------------------------------
  // Basic matching
  // ---------------------------------------------------------------------------

  test('selects exact match from candidates', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen'),
        song(id: '2', title: 'We Will Rock You', artist: 'Queen'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('selects correct song when multiple artists have same title', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'RUNAWAY', artist: 'Aurora'),
      candidates: [
        song(id: '1', title: 'Runaway', artist: 'Kanye West'),
        song(id: '2', title: 'Runaway', artist: 'Aurora'),
        song(id: '3', title: 'Runaway', artist: 'Bon Jovi'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '2');
  });

  // ---------------------------------------------------------------------------
  // Threshold behaviour
  // ---------------------------------------------------------------------------

  test('returns null when no candidate exceeds minimum score', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
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
      track: lastFm(title: 'Heart Attack', artist: 'Pokelawls'),
      candidates: [song(id: '1', title: 'Heart Attack', artist: 'Demi Lovato')],
    );

    expect(match, isNull);
  });

  test('returns null when title partially matches but artist is completely different', () {
    // "RUNAWAY" by Aurora should NOT match a search for "RUNWAY" by Pokelawls.
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'RUNWAY', artist: 'Pokelawls'),
      candidates: [song(id: '1', title: 'RUNAWAY', artist: 'Aurora')],
    );

    expect(match, isNull);
  });

  test('returns null for empty candidate list', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [],
    );

    expect(match, isNull);
  });

  // ---------------------------------------------------------------------------
  // Live version penalty
  // ---------------------------------------------------------------------------

  test('prefers studio version over live recording', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
      candidates: [
        song(id: 'live', title: 'Bohemian Rhapsody (Live)', artist: 'Queen'),
        song(id: 'studio', title: 'Bohemian Rhapsody', artist: 'Queen'),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, 'studio');
  });

  test('penalises songs on live albums', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Bohemian Rhapsody', artist: 'Queen'),
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

    expect(match, isNotNull);
    expect(match!.id, 'studio');
  });

  // ---------------------------------------------------------------------------
  // Normalisation edge cases
  // ---------------------------------------------------------------------------

  test('matches despite parenthetical differences', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Blinding Lights', artist: 'The Weeknd'),
      candidates: [
        song(
          id: '1',
          title: 'Blinding Lights (Official Audio)',
          artist: 'The Weeknd',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches despite feat. in title', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'Locked Out of Heaven', artist: 'Bruno Mars'),
      candidates: [
        song(
          id: '1',
          title: 'Locked Out of Heaven (feat. Someone)',
          artist: 'Bruno Mars',
        ),
      ],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches case-insensitively', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: 'bohemian rhapsody', artist: 'queen'),
      candidates: [song(id: '1', title: 'Bohemian Rhapsody', artist: 'Queen')],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });

  test('matches when punctuation differs', () {
    final match = pickBestArtistTopTrackMatch(
      track: lastFm(title: "Don't Stop Me Now", artist: 'Queen'),
      candidates: [song(id: '1', title: 'Dont Stop Me Now', artist: 'Queen')],
    );

    expect(match, isNotNull);
    expect(match!.id, '1');
  });
}
