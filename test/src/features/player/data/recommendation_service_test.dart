import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart'
    show kLocalTrackMatcherSnapshotYieldChunkSize;
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

/// Holds the first chunk yield until the catalog change or disposal finishes.
Future<T> _duringChunkYield<T>(
  Future<T> Function() build,
  Future<void> Function() duringYield, {
  List<Timer>? timers,
}) async {
  var reachedYield = false;
  final result = await runZoned(
    build,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        final pause = duration == Duration.zero && !reachedYield;
        if (pause) reachedYield = true;
        final timer = parent.createTimer(zone, duration, () {
          if (pause) {
            unawaited(duringYield().then((_) => callback()));
          } else {
            callback();
          }
        });
        timers?.add(timer);
        return timer;
      },
    ),
  );
  expect(reachedYield, isTrue, reason: 'The pool must yield during its build');
  return result;
}

class _CountingLastFmApiClient extends LastFmApiClient {
  new() : super(apiKey: 'test-key');

  int similarTrackCalls = 0;

  @override
  Future<LastFmTrackFetchResult> getSimilarTracksResult({
    required String artist,
    required String track,
    int limit = 20,
  }) async {
    similarTrackCalls++;
    return const LastFmTrackFetchResult(
      outcome: LastFmFetchOutcome.noResults,
      tracks: <LastFmTrackRecommendation>[],
    );
  }
}

void main() {
  Song song(String id, String artist, {String? recording}) => Song(
    id: id,
    title: 'Title $id',
    artist: artist,
    musicBrainzId: recording,
  );

  test('radio interleaves related and familiar tracks without duplicates', () {
    final related = <Song>[
      for (var index = 0; index < 8; index++)
        song('related-$index', 'Artist $index'),
    ];
    final familiar = <Song>[
      for (var index = 0; index < 4; index++)
        song('familiar-$index', 'Familiar $index'),
    ];
    final batch = composeRadioBatch(
      related: related,
      familiar: familiar,
      shuffle: const <Song>[],
      excludedIds: <String>{'related-0'},
    );

    expect(batch, hasLength(10));
    expect(batch.map((song) => song.id).toSet(), hasLength(10));
    expect(batch.any((song) => song.id == 'related-0'), isFalse);
    expect(
      batch.where((song) => song.id.startsWith('familiar-')),
      hasLength(3),
    );
    for (var index = 1; index < batch.length; index++) {
      expect(batch[index].artist, isNot(batch[index - 1].artist));
    }
  });

  test('small library fills from shuffle and avoids duplicate recordings', () {
    final batch = composeRadioBatch(
      related: <Song>[
        song('edition-a', 'One', recording: 'same-recording'),
        song('edition-b', 'One', recording: 'same-recording'),
      ],
      familiar: <Song>[song('familiar', 'Two')],
      shuffle: <Song>[song('other', 'Three')],
      excludedIds: const <String>{},
    );

    expect(batch.map((song) => song.id), contains('edition-a'));
    expect(batch.map((song) => song.id), isNot(contains('edition-b')));
    expect(batch, hasLength(3));
  });

  test('songs with non-Latin titles are different recordings', () {
    final batch = composeRadioBatch(
      related: const <Song>[
        Song(id: 'arashi', title: '花', artist: '嵐'),
        Song(id: 'oor', title: '残響リファレンス', artist: 'ワンオクロック'),
        Song(id: 'bts', title: '봄날', artist: '방탄소년단'),
        Song(id: 'oor-again', title: '「残響リファレンス」', artist: 'ワンオクロック'),
      ],
      familiar: const <Song>[],
      shuffle: const <Song>[],
      excludedIds: const <String>{},
    );

    expect(batch.map((song) => song.id), <String>['arashi', 'oor', 'bts']);
  });

  test(
    'server mix calls generic similarity first and accepts an empty result',
    () async {
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);
      final container = ProviderContainer(
        overrides: [subsonicApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      final result = await container
          .read(recommendationServiceProvider)
          .serverMix('seed');
      expect(result.issue, RecommendationIssue.empty);
      verifyNever(
        () => api.getInstantMix(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test('server mix uses the original standard endpoint when version 2 is unsupported', () async {
    final api = _MockSubsonicApiClient();
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(
      const SubsonicNotFoundException(message: 'Unsupported endpoint'),
    );
    when(
      () => api.getLegacySimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => <Song>[song('fallback', 'Artist')]);
    final container = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    final result = await container
        .read(recommendationServiceProvider)
        .serverMix('seed');
    expect(result.songs.single.id, 'fallback');
    expect(result.source, RecommendationSource.server);
    verifyNever(
      () => api.getInstantMix(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test('Navidrome instant mix is the last fallback', () async {
    final api = _MockSubsonicApiClient();
    const unsupported = SubsonicNotFoundException(message: 'Unsupported');
    when(
      () => api.getSimilarSongs2(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(unsupported);
    when(
      () => api.getLegacySimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenThrow(unsupported);
    when(
      () => api.getInstantMix(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => <Song>[song('navidrome', 'Artist')]);
    final container = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final result = await container
        .read(recommendationServiceProvider)
        .serverMix('seed');
    expect(result.songs.single.id, 'navidrome');
    expect(result.source, RecommendationSource.instantMix);
  });

  test('the eligible pool is released when its window ends', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(id: 'song-1', title: 'One'),
    ]);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          recommendationServiceProvider.overrideWith(
            (ref) => RecommendationService(
              ref,
              eligibleLibraryMaxAge: const Duration(milliseconds: 50),
            ),
          ),
        ],
      ),
    );
    addTearDown(container.dispose);
    final service = container.read(recommendationServiceProvider);

    await service.eligibleLibrary(const RadioFilters());
    expect(service.debugHasEligibleLibrary, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(service.debugHasEligibleLibrary, isFalse);

    // A later read rebuilds the pool.
    expect(
      (await service.eligibleLibrary(const RadioFilters())).single.id,
      'song-1',
    );
    expect(service.debugHasEligibleLibrary, isTrue);
  }, skip: !sqliteAvailable);

  test('the eligible pool precomputes recording identities once', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'song-1',
        title: 'Song (Live)',
        artistName: const Value('Artist'),
      ),
      SongsTableCompanion.insert(
        id: 'song-2',
        title: 'Other',
        recordingMbid: const Value('ABC-123'),
      ),
    ]);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
        ],
      ),
    );
    addTearDown(container.dispose);
    final service = container.read(recommendationServiceProvider);

    expect(
      await service.debugRecordingIdentity(const RadioFilters(), 'song-1'),
      RecommendationService.debugIdentity('Artist', 'Song (Live)'),
    );
    expect(
      await service.debugRecordingIdentity(const RadioFilters(), 'song-2'),
      'mbid:abc-123',
    );
    expect(
      service.debugCachedNormalizedIdentity('song-2'),
      RecommendationService.debugIdentity('', 'Other'),
    );
  }, skip: !sqliteAvailable);

  for (final radio in [false, true]) {
    test(
      radio
          ? 'radio exclusions use identities from the returned song snapshot'
          : 'recording identities use the returned song snapshot',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          for (
            var index = 0;
            index <= kLocalTrackMatcherSnapshotYieldChunkSize;
            index++
          )
            SongsTableCompanion.insert(
              id: 'song-$index',
              title: index < 2 ? 'Original' : 'Title $index',
              artistName: const Value('Artist'),
            ),
        ]);
        final container = ProviderContainer(
          overrides: withTestDatabase(
            database,
            overrides: [
              networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
              subsonicApiProvider.overrideWithValue(null),
              lastFmApiClientProvider.overrideWithValue(null),
            ],
          ),
        );
        addTearDown(container.dispose);
        final service = container.read(recommendationServiceProvider);

        Future<void> changeCatalog() async {
          await database.libraryDao.upsertSongs(<SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'song-0',
              title: 'Updated',
              artistName: const Value('Artist'),
            ),
          ]);
          await pumpEventQueue();
        }

        if (radio) {
          final batch = await _duringChunkYield(
            () => service.personalRadio(
              const RadioFilters(),
              excludedIds: {'song-0'},
              count: kLocalTrackMatcherSnapshotYieldChunkSize + 1,
            ),
            changeCatalog,
          );
          expect(batch.songs, isNotEmpty);
          expect(batch.songs.map((song) => song.id), isNot(contains('song-1')));
        } else {
          final identity = await _duringChunkYield(
            () =>
                service.debugRecordingIdentity(const RadioFilters(), 'song-0'),
            changeCatalog,
          );
          expect(
            identity,
            RecommendationService.debugIdentity('Artist', 'Original'),
          );
        }
        expect(
          (await service.eligibleLibrary(const RadioFilters()))
              .firstWhere((song) => song.id == 'song-0')
              .title,
          'Updated',
        );
      },
      skip: !sqliteAvailable,
    );
  }

  test('disposal during a pool build retains no cache or timer', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (
        var index = 0;
        index <= kLocalTrackMatcherSnapshotYieldChunkSize;
        index++
      )
        SongsTableCompanion.insert(id: 'song-$index', title: 'Title $index'),
    ]);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
        ],
      ),
    );
    addTearDown(container.dispose);
    final service = container.read(recommendationServiceProvider);
    final timers = <Timer>[];
    try {
      final pool = await _duringChunkYield(
        () => service.eligibleLibrary(const RadioFilters()),
        () async => container.dispose(),
        timers: timers,
      );
      expect(pool, hasLength(kLocalTrackMatcherSnapshotYieldChunkSize + 1));
      expect(service.debugHasEligibleLibrary, isFalse);
      expect(timers.where((timer) => timer.isActive), isEmpty);
    } finally {
      // Also clean up the leaked release timer on the pre-fix failure path.
      for (final timer in timers) {
        timer.cancel();
      }
    }
  }, skip: !sqliteAvailable);

  test(
    'the eligible library follows catalog changes between refills',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-1', title: 'One'),
        SongsTableCompanion.insert(id: 'song-2', title: 'Two'),
      ]);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
          ],
        ),
      );
      addTearDown(container.dispose);
      final service = container.read(recommendationServiceProvider);

      Future<Set<String>> ids() async =>
          (await service.eligibleLibrary(const RadioFilters()))
              .map((song) => song.id)
              .toSet();

      expect(await ids(), <String>{'song-1', 'song-2'});
      expect(await ids(), <String>{'song-1', 'song-2'});

      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(id: 'song-3', title: 'Three'),
      ]);
      await pumpEventQueue();

      expect(await ids(), <String>{'song-1', 'song-2', 'song-3'});
    },
    skip: !sqliteAvailable,
  );

  group('Last.fm integration gates', () {
    Future<_CountingLastFmApiClient> runRadio(IntegrationPolicy policy) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        for (var i = 0; i < 6; i++)
          SongsTableCompanion.insert(id: 'song-$i', title: 'Title $i'),
      ]);
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);
      final lastFm = _CountingLastFmApiClient();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(api),
            lastFmApiClientProvider.overrideWithValue(lastFm),
            integrationPolicyProvider.overrideWithValue(policy),
          ],
        ),
      );
      addTearDown(container.dispose);
      await container
          .read(recommendationServiceProvider)
          .personalRadio(const RadioFilters(), excludedIds: const <String>{});
      return lastFm;
    }

    test('radio fill asks Last.fm while allowed', () async {
      expect(
        (await runRadio(const IntegrationPolicy(lastFmVerified: true)))
            .similarTrackCalls,
        1,
      );
    }, skip: !sqliteAvailable);

    for (final entry in const <String, IntegrationPolicy>{
      'the radio switch is off': IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'lastfm.radio'},
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
      test('radio fill never asks Last.fm when ${entry.key}', () async {
        expect((await runRadio(entry.value)).similarTrackCalls, 0);
      }, skip: !sqliteAvailable);
    }

    test('radio fill is not blocked by the Same Vibes switch', () async {
      expect(
        (await runRadio(
          const IntegrationPolicy(
            lastFmVerified: true,
            disabledKeys: {'lastfm.sameVibes'},
          ),
        )).similarTrackCalls,
        1,
      );
    }, skip: !sqliteAvailable);
  });
}
