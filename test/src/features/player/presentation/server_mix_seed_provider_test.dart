import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/features/player/presentation/server_mix_seed_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

class _Api extends Mock implements SubsonicApiClient;

void main() {
  late _Api api;
  late ProviderContainer container;

  setUp(() {
    api = _Api();
    container = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(api)],
    );
  });
  tearDown(() => container.dispose());

  test('server-addressable seeds need no library-copy lookup', () async {
    expect(
      await container.read(serverMixSeedAvailableProvider('seed').future),
      isTrue,
    );
    verifyZeroInteractions(api);
  });

  test('a remote seed without a server is unavailable', () async {
    final offline = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(null)],
    );
    addTearDown(offline.dispose);
    expect(
      await offline.read(serverMixSeedAvailableProvider('ext-seed').future),
      isFalse,
    );
    expect(
      await offline.read(serverMixSeedAvailableProvider('seed').future),
      isTrue,
    );
  });

  for (final entry in <String, bool>{
    ' library-copy ': true,
    'ext-seed': false,
    'ext-other': false,
    'remote-other': false,
    '': false,
  }.entries) {
    test(
      'remote library-copy lookup accepts ${entry.key}: ${entry.value}',
      () async {
        when(() => api.getSong('ext-seed'))
            .thenAnswer((_) async => Song(id: entry.key, title: 'Seed'));
        expect(
          await container.read(
            serverMixSeedAvailableProvider('ext-seed').future,
          ),
          entry.value,
        );
        verify(() => api.getSong('ext-seed')).called(1);
      },
    );
  }

  test('a failed Subsonic library-copy lookup is unavailable', () async {
    when(() => api.getSong('ext-seed'))
        .thenThrow(const SubsonicConnectionException('Unavailable'));
    expect(
      await container.read(serverMixSeedAvailableProvider('ext-seed').future),
      isFalse,
    );
  });

  test(
    'Server Mix uses the same trimmed library copy as its seed gate',
    () async {
      when(() => api.getSong('ext-seed')).thenAnswer(
        (_) async => const Song(id: ' library-copy ', title: 'Seed'),
      );
      when(() => api.getSimilarSongs2('library-copy', count: 10)).thenAnswer(
        (_) async => const [
          Song(id: 'related', title: 'Related'),
          Song(id: 'library-copy', title: 'Seed'),
          Song(id: 'ext-seed', title: 'Remote Seed'),
        ],
      );
      expect(
        await container.read(serverMixSeedAvailableProvider('ext-seed').future),
        isTrue,
      );
      final mix = await container
          .read(recommendationServiceProvider)
          .serverMix('ext-seed');
      expect(mix.songs.map((song) => song.id), ['related']);
      verify(() => api.getSong('ext-seed')).called(2);
      verify(() => api.getSimilarSongs2('library-copy', count: 10)).called(1);
    },
  );
}
