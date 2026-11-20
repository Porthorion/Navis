import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
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
  new([
    this.result = const LastFmTrackFetchResult(
      outcome: LastFmFetchOutcome.noResults,
      tracks: <LastFmTrackRecommendation>[],
    ),
  ]) : super(apiKey: 'test-key');

  final LastFmTrackFetchResult result;
  int similarTrackCalls = 0;

  @override
  Future<LastFmTrackFetchResult> getSimilarTracksResult({
    required String artist,
    required String track,
    int limit = 20,
  }) async {
    similarTrackCalls++;
    return result;
  }
}

/// A Random whose shuffles keep their order, so the seed is the first starred
/// song in library (id) order.
class _KeepOrderRandom implements Random {
  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => max - 1;
}

/// Records the Deezer requests of the radio leg. [related] answers every
/// artist; a null [searchResult] means "not on Deezer".
class _FakeDeezer extends DeezerApiClient {
  new() : super(dio: Dio());

  final List<String> searched = <String>[];
  final List<bool> relatedBackground = <bool>[];
  final List<CancelToken?> relatedTokens = <CancelToken?>[];
  List<DeezerArtist> related = const <DeezerArtist>[];
  bool onDeezer = true;
  Exception? relatedError;
  bool hang = false;

  int get requests => searched.length + relatedBackground.length;

  @override
  Future<List<DeezerArtist>> searchArtists(
    String name, {
    int limit = 25,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    searched.add(name);
    return onDeezer ? [DeezerArtist(id: 7, name: name)] : const [];
  }

  @override
  Future<List<DeezerArtist>> getRelatedArtists(
    int artistId, {
    int limit = 20,
    CancelToken? cancelToken,
    bool background = false,
  }) async {
    relatedBackground.add(background);
    relatedTokens.add(cancelToken);
    if (hang) {
      await cancelToken!.whenCancel;
      throw DioException(
        requestOptions: RequestOptions(path: 'artist/$artistId/related'),
        type: DioExceptionType.cancel,
      );
    }
    if (relatedError case final error?) throw error;
    return related;
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
    Future<RecommendationBatch> radioBatchWith(
      LastFmTrackFetchResult result, {
      IntegrationPolicy policy = const IntegrationPolicy(lastFmVerified: true),
      bool withClient = true,
      bool bundledKey = false,
    }) async {
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
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(api),
            lastFmApiClientProvider.overrideWithValue(
              withClient ? _CountingLastFmApiClient(result) : null,
            ),
            integrationPolicyProvider.overrideWithValue(policy),
            lastFmBundledKeyProvider.overrideWithValue(bundledKey),
          ],
        ),
      );
      addTearDown(container.dispose);
      return container
          .read(recommendationServiceProvider)
          .personalRadio(const RadioFilters(), excludedIds: const <String>{});
    }

    LastFmTrackFetchResult failure(
      LastFmFetchOutcome outcome, {
      int? code,
      int? status,
    }) => LastFmTrackFetchResult(
      outcome: outcome,
      tracks: const <LastFmTrackRecommendation>[],
      apiErrorCode: code,
      statusCode: status,
    );

    test('a rejected key still plays radio and reports invalidKey', () async {
      final batch = await radioBatchWith(
        failure(LastFmFetchOutcome.apiError, code: 10),
      );
      expect(batch.songs, isNotEmpty);
      expect(batch.issue, RecommendationIssue.none);
      expect(batch.lastFmIssue, RecommendationIssue.invalidKey);
    }, skip: !sqliteAvailable);

    test('a rejected bundled key stays silent (#694)', () async {
      final batch = await radioBatchWith(
        failure(LastFmFetchOutcome.apiError, code: 10),
        bundledKey: true,
      );
      expect(batch.songs, isNotEmpty);
      expect(batch.lastFmIssue, RecommendationIssue.none);
    }, skip: !sqliteAvailable);

    // One test database per test, like runRadio below: several open at
    // once trip drift's multiple-instances warning (a check.sh blocker).
    test('no Last.fm key at all stays silent', () async {
      final batch = await radioBatchWith(
        failure(LastFmFetchOutcome.apiError, code: 10),
        withClient: false,
      );
      expect(batch.songs, isNotEmpty);
      expect(batch.lastFmIssue, RecommendationIssue.none);
    }, skip: !sqliteAvailable);

    for (final entry in <String, (LastFmTrackFetchResult, IntegrationPolicy)>{
      'a rate limit': (
        failure(LastFmFetchOutcome.apiError, status: 429),
        const IntegrationPolicy(lastFmVerified: true),
      ),
      'a network failure': (
        failure(LastFmFetchOutcome.networkError),
        const IntegrationPolicy(lastFmVerified: true),
      ),
      'an empty answer': (
        failure(LastFmFetchOutcome.noResults),
        const IntegrationPolicy(lastFmVerified: true),
      ),
      'switched-off Last.fm': (
        failure(LastFmFetchOutcome.apiError, code: 10),
        const IntegrationPolicy(),
      ),
    }.entries) {
      test('${entry.key} stays silent', () async {
        final (result, policy) = entry.value;
        expect(
          (await radioBatchWith(result, policy: policy)).lastFmIssue,
          RecommendationIssue.none,
        );
      }, skip: !sqliteAvailable);
    }

    Future<RecommendationBatch> runRadioWith(
      LastFmApiClient lastFm,
      IntegrationPolicy policy,
    ) async {
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
      return container
          .read(recommendationServiceProvider)
          .personalRadio(const RadioFilters(), excludedIds: const <String>{});
    }

    Future<_CountingLastFmApiClient> runRadio(IntegrationPolicy policy) async {
      final lastFm = _CountingLastFmApiClient();
      await runRadioWith(lastFm, policy);
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

    test('a seed with no artist is not a rejected key', () async {
      final batch = await runRadioWith(
        LastFmApiClient(apiKey: 'test-key'),
        const IntegrationPolicy(lastFmVerified: true),
      );
      expect(batch.songs, isNotEmpty);
      expect(batch.lastFmIssue, RecommendationIssue.none);
    }, skip: !sqliteAvailable);

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

  group('Deezer related-artist leg', () {
    late Directory cacheRoot;
    late _FakeDeezer deezer;

    setUp(() {
      cacheRoot = Directory.systemTemp.createTempSync('radio_deezer_test_');
      deezer = _FakeDeezer();
    });

    tearDown(() {
      if (cacheRoot.existsSync()) cacheRoot.deleteSync(recursive: true);
    });

    DeezerArtist related(String name, int id) =>
        DeezerArtist(id: id, name: name);

    // 'a-seed' sorts first, so it is the radio seed under _KeepOrderRandom.
    Future<NavisDatabase> library({
      Set<String> starred = const {'a-seed', 'alpha-2'},
      int fillers = 0,
    }) async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await database.libraryDao.upsertArtists(<ArtistsTableCompanion>[
        for (final artist in const {
          'ar-seed': 'Seed Artist',
          'ar-alpha': 'Alpha',
          'ar-beta': 'Beta',
          'ar-gamma': 'Gamma',
          'ar-delta': 'Delta',
        }.entries)
          ArtistsTableCompanion.insert(id: artist.key, name: artist.value),
      ]);
      SongsTableCompanion row(String id, String artistId, String artist) =>
          SongsTableCompanion.insert(
            id: id,
            title: 'Title $id',
            artistId: Value(artistId),
            artistName: Value(artist),
            starred: Value(starred.contains(id) ? DateTime(2026) : null),
          );
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        row('a-seed', 'ar-seed', 'Seed Artist'),
        for (final n in [1, 2, 3]) row('alpha-$n', 'ar-alpha', 'Alpha'),
        for (final n in [1, 2, 3]) row('beta-$n', 'ar-beta', 'Beta'),
        for (final n in [1, 2, 3]) row('gamma-$n', 'ar-gamma', 'Gamma'),
        for (var n = 0; n < fillers; n++) row('delta-$n', 'ar-delta', 'Delta'),
      ]);
      return database;
    }

    ProviderContainer containerFor(
      NavisDatabase database, {
      IntegrationPolicy policy = const IntegrationPolicy(),
      LastFmApiClient? lastFm,
      List<Song> serverSimilar = const <Song>[],
      Duration timeout = const Duration(seconds: 6),
    }) {
      final api = _MockSubsonicApiClient();
      when(
        () => api.getSimilarSongs2(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => serverSimilar);
      final root = cacheRoot;
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            networkTypeProvider.overrideWith((ref) => NetworkType.wifi),
            subsonicApiProvider.overrideWithValue(api),
            deezerApiClientProvider.overrideWithValue(deezer),
            integrationJsonCacheProvider.overrideWithValue(
              IntegrationJsonCache(readRootDirectory: () async => root),
            ),
            lastFmApiClientProvider.overrideWithValue(lastFm),
            lastFmBundledKeyProvider.overrideWithValue(false),
            integrationPolicyProvider.overrideWithValue(policy),
            recommendationServiceProvider.overrideWith(
              (ref) => RecommendationService(
                ref,
                random: _KeepOrderRandom(),
                deezerLegTimeout: timeout,
              ),
            ),
          ],
        ),
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<RecommendationBatch> radio(
      ProviderContainer container, {
      Set<String> excluded = const <String>{},
    }) => container
        .read(recommendationServiceProvider)
        .personalRadio(const RadioFilters(), excludedIds: excluded);

    Set<String> ids(Iterable<Song> songs) => songs.map((s) => s.id).toSet();

    test('picks up to two songs per related artist, starred first, never the '
        'seed, in relatedness order', () async {
      final database = await library();
      final container = containerFor(database);
      deezer.related = [
        related('Beta', 2),
        related('Not In Library', 3),
        related('Alpha', 4),
        related('Seed Artist', 5),
      ];
      final service = container.read(recommendationServiceProvider);
      final pool = await service.eligibleLibrary(const RadioFilters());
      final seed = pool.firstWhere((song) => song.id == 'a-seed');
      final songs = await service.deezerMatches(
        Song(id: 'a-seed', title: 'Title a-seed', artist: 'Seed Artist'),
        pool.where((song) => song.id != 'beta-1').toList(),
        count: 10,
      );
      expect(seed.artistName, 'Seed Artist');
      // Beta first (relatedness order), its pool songs only (beta-1 left the
      // pool); Alpha's starred song before the other one; no seed artist.
      expect(songs.map((song) => song.id).toList(), [
        'beta-2',
        'beta-3',
        'alpha-2',
        'alpha-1',
      ]);
    }, skip: !sqliteAvailable);

    test(
      'radio takes related-artist songs and reports the Deezer source',
      () async {
        final database = await library();
        final container = containerFor(database);
        deezer.related = [related('Alpha', 4)];
        final batch = await radio(container, excluded: {'alpha-1'});
        expect(batch.source, RecommendationSource.deezer);
        expect(ids(batch.songs), containsAll(<String>['alpha-2', 'alpha-3']));
        expect(ids(batch.songs), isNot(contains('alpha-1')));
        expect(deezer.searched, ['Seed Artist']);
        expect(batch.issue, RecommendationIssue.none);
      },
      skip: !sqliteAvailable,
    );

    test('background reaches the related-artists request', () async {
      final database = await library();
      final container = containerFor(database);
      deezer.related = [related('Alpha', 4)];
      await radio(container);
      expect(deezer.relatedBackground, [true]);
    }, skip: !sqliteAvailable);

    for (final entry in const <String, IntegrationPolicy>{
      'the radio switch is off': IntegrationPolicy(
        disabledKeys: {'deezer.radio'},
      ),
      'the Deezer service is off': IntegrationPolicy(disabledKeys: {'deezer'}),
      'the master switch is off': IntegrationPolicy(masterEnabled: false),
    }.entries) {
      test('no Deezer request when ${entry.key}', () async {
        final database = await library();
        final container = containerFor(database, policy: entry.value);
        deezer.related = [related('Alpha', 4)];
        final batch = await radio(container);
        expect(deezer.requests, 0);
        expect(batch.source, isNot(RecommendationSource.deezer));
        expect(batch.songs, isNotEmpty);
      }, skip: !sqliteAvailable);
    }

    for (final entry in <String, Exception>{
      'a quota answer': const DeezerApiException(code: 4, type: 'Exception'),
      'another Deezer error': const DeezerApiException(code: 300),
      'a transport error': DioException(
        requestOptions: RequestOptions(path: 'x'),
        type: DioExceptionType.connectionError,
      ),
    }.entries) {
      test(
        '${entry.key} leaves radio built from local taste, silently',
        () async {
          final database = await library();
          final container = containerFor(database);
          deezer.relatedError = entry.value;
          final batch = await radio(container);
          expect(batch.songs, isNotEmpty);
          expect(batch.source, RecommendationSource.localTaste);
          expect(batch.issue, RecommendationIssue.none);
          expect(batch.lastFmIssue, RecommendationIssue.none);
        },
        skip: !sqliteAvailable,
      );
    }

    test(
      'a hanging Deezer is cancelled after the cap and radio completes',
      () async {
        final database = await library();
        final container = containerFor(
          database,
          timeout: const Duration(milliseconds: 50),
        );
        deezer.hang = true;
        final batch = await radio(container);
        expect(batch.songs, isNotEmpty);
        expect(batch.source, RecommendationSource.localTaste);
        expect(deezer.relatedTokens.single!.isCancelled, isTrue);
      },
      skip: !sqliteAvailable,
    );

    test('cancelling the caller cancels the Deezer request', () async {
      final database = await library();
      final container = containerFor(database);
      deezer.hang = true;
      final caller = CancelToken();
      final batch = container
          .read(recommendationServiceProvider)
          .personalRadio(
            const RadioFilters(),
            excludedIds: const <String>{},
            cancelToken: caller,
          );
      while (deezer.relatedTokens.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      caller.cancel();
      expect((await batch).songs, isNotEmpty);
      expect(deezer.relatedTokens.single!.isCancelled, isTrue);
    }, skip: !sqliteAvailable);

    test(
      'a seed artist missing from Deezer falls through to Last.fm',
      () async {
        final database = await library();
        final lastFm = _CountingLastFmApiClient(
          const LastFmTrackFetchResult(
            outcome: LastFmFetchOutcome.success,
            tracks: [
              LastFmTrackRecommendation(
                artist: 'Gamma',
                title: 'Title gamma-1',
              ),
            ],
          ),
        );
        final container = containerFor(
          database,
          policy: const IntegrationPolicy(lastFmVerified: true),
          lastFm: lastFm,
        );
        deezer.onDeezer = false;
        final batch = await radio(container);
        expect(deezer.relatedBackground, isEmpty);
        expect(lastFm.similarTrackCalls, 1);
        expect(batch.source, RecommendationSource.lastFm);
        expect(ids(batch.songs), contains('gamma-1'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'the server filling the related slots means no Deezer request',
      () async {
        final database = await library(fillers: 10);
        final container = containerFor(
          database,
          serverSimilar: [
            for (var n = 0; n < 10; n++)
              Song(id: 'delta-$n', title: 'Title delta-$n', artist: 'Delta'),
          ],
        );
        deezer.related = [related('Alpha', 4)];
        final batch = await radio(container);
        expect(batch.source, RecommendationSource.server);
        expect(deezer.requests, 0);
      },
      skip: !sqliteAvailable,
    );

    group('a user-supplied Last.fm key (no bundled key)', () {
      const verified = IntegrationPolicy(lastFmVerified: true);
      const gammaMatch = LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.success,
        tracks: [
          LastFmTrackRecommendation(artist: 'Gamma', title: 'Title gamma-1'),
        ],
      );

      test('Deezer finding nothing hands over to Last.fm', () async {
        final database = await library();
        final lastFm = _CountingLastFmApiClient(gammaMatch);
        final container = containerFor(
          database,
          policy: verified,
          lastFm: lastFm,
        );
        final batch = await radio(container);
        expect(lastFm.similarTrackCalls, 1);
        expect(batch.source, RecommendationSource.lastFm);
        expect(ids(batch.songs), contains('gamma-1'));
      }, skip: !sqliteAvailable);

      test('a rejected key still reports invalidKey', () async {
        final database = await library();
        final container = containerFor(
          database,
          policy: verified,
          lastFm: _CountingLastFmApiClient(
            const LastFmTrackFetchResult(
              outcome: LastFmFetchOutcome.apiError,
              tracks: <LastFmTrackRecommendation>[],
              apiErrorCode: 10,
            ),
          ),
        );
        final batch = await radio(container);
        expect(batch.songs, isNotEmpty);
        expect(batch.lastFmIssue, RecommendationIssue.invalidKey);
      }, skip: !sqliteAvailable);

      test('Deezer filling the batch means Last.fm is not called', () async {
        final database = await library(fillers: 3);
        final lastFm = _CountingLastFmApiClient(gammaMatch);
        final container = containerFor(
          database,
          policy: verified,
          lastFm: lastFm,
        );
        deezer.related = [
          related('Alpha', 4),
          related('Beta', 5),
          related('Gamma', 6),
          related('Delta', 8),
        ];
        final batch = await radio(container);
        expect(batch.source, RecommendationSource.deezer);
        expect(lastFm.similarTrackCalls, 0);
      }, skip: !sqliteAvailable);
    });
  });

  test(
    'Last.fm "track not found" reads as an empty answer, not a network failure',
    () {
      RecommendationIssue issueFor(LastFmTrackFetchResult result) =>
          lastFmRecommendationIssue(result);
      expect(
        issueFor(
          const LastFmTrackFetchResult(
            outcome: LastFmFetchOutcome.apiError,
            tracks: <LastFmTrackRecommendation>[],
            apiErrorCode: 6,
          ),
        ),
        RecommendationIssue.empty,
      );
      expect(
        issueFor(
          const LastFmTrackFetchResult(
            outcome: LastFmFetchOutcome.apiError,
            tracks: <LastFmTrackRecommendation>[],
            apiErrorCode: 10,
          ),
        ),
        RecommendationIssue.invalidKey,
      );
    },
  );
}
