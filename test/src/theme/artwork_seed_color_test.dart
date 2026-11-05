import 'package:file/file.dart' show File;
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/theme/dynamic_accent_provider.dart';
import 'package:navis/src/utils/connectivity.dart';

class _UnusedFileSystem implements FileSystem {
  @override
  Future<File> createFile(String name) => throw UnimplementedError();
}

class _RecordingCache extends DynamicAccentColorCache {
  new(this.answer);

  final int? answer;
  final Map<String, int> known = <String, int>{};

  @override
  int? peek(String source) => known[source];
  final List<String> sources = <String>[];

  @override
  Future<int?> resolve({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) async {
    sources.add(source);
    return answer;
  }
}

SubsonicApiClient _api() => SubsonicApiClient(
  baseUrl: 'https://example.com',
  authConfig: const SubsonicAuthConfig(
    username: 'a',
    password: 'b',
    apiVersion: '1.16.1',
  ),
  enableLogging: false,
);

const _request = (coverArtId: 'c1', size: 208);

ProviderContainer _container(
  _RecordingCache cache, {
  NetworkType network = NetworkType.wifi,
  bool prefetchOnMobileData = true,
  SubsonicApiClient? api,
  bool? metered,
}) {
  final container = ProviderContainer(
    overrides: <Override>[
      dynamicAccentColorCacheProvider.overrideWithValue(cache),
      coverArtCacheManagerProvider.overrideWithValue(
        CacheManager(
          Config(
            'navis-seed-test',
            repo: NonStoringObjectProvider(),
            fileSystem: _UnusedFileSystem(),
          ),
        ),
      ),
      subsonicApiProvider.overrideWithValue(api ?? _api()),
      networkTypeProvider.overrideWithValue(network),
      nativeNetworkMeteredProvider.overrideWith((ref) async => metered),
      appSettingsProvider.overrideWithValue(
        AsyncData(
          const AppSettingsModel.defaults().copyWith(
            prefetchNextOnMobileData: prefetchOnMobileData,
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('artworkSeedColorProvider', () {
    test('reads the cover at the size the card shows', () async {
      final cache = _RecordingCache(0xFF112233);
      final seed = await _container(cache)
          .read(artworkSeedColorProvider(_request).future);
      expect(seed, 0xFF112233);
      expect(cache.sources, <String>['id:c1@208']);
    });

    test('does not fetch offline', () async {
      final cache = _RecordingCache(0xFF112233);
      final seed = await _container(
        cache,
        network: NetworkType.offline,
      ).read(artworkSeedColorProvider(_request).future);
      expect(seed, isNull);
      expect(cache.sources, isEmpty);
    });

    test('does not fetch on mobile data unless allowed', () async {
      final blocked = _RecordingCache(1);
      await _container(
        blocked,
        network: NetworkType.cellular,
        prefetchOnMobileData: false,
      ).read(artworkSeedColorProvider(_request).future);
      expect(blocked.sources, isEmpty);

      final metered = _RecordingCache(1);
      final meteredContainer = _container(
        metered,
        prefetchOnMobileData: false,
        metered: true,
      );
      await meteredContainer.read(nativeNetworkMeteredProvider.future);
      await meteredContainer.read(artworkSeedColorProvider(_request).future);
      expect(metered.sources, isEmpty);

      final allowed = _RecordingCache(1);
      await _container(
        allowed,
        network: NetworkType.cellular,
      ).read(artworkSeedColorProvider(_request).future);
      expect(allowed.sources, hasLength(1));
    });

    test('a colour the player already read costs no fetch', () async {
      final cache = _RecordingCache(null)..known['id:c1'] = 0xFFABCDEF;
      final seed = await _container(
        cache,
        network: NetworkType.offline,
      ).read(artworkSeedColorProvider(_request).future);
      expect(seed, 0xFFABCDEF);
      expect(cache.sources, isEmpty);
    });

    test('a cover that failed is asked again when read afresh', () async {
      final cache = _RecordingCache(null);
      final first = _container(cache);
      expect(
        await first.read(artworkSeedColorProvider(_request).future),
        isNull,
      );
      first.dispose();
      final second = _container(cache);
      expect(
        await second.read(artworkSeedColorProvider(_request).future),
        isNull,
      );
      expect(cache.sources, <String>['id:c1@208', 'id:c1@208']);
    });
  });
}
