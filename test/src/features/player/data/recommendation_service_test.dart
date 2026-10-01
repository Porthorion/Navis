import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

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
}
