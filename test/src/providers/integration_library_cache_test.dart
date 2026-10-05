import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/home/presentation/home_deezer_providers.dart';
import 'package:navis/src/features/integrations/data/deezer_cache.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/presentation/artist_top_tracks_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../../helpers/test_database.dart';

void main() {
  test('wiping server data deletes remembered matches, Trending matches and Deezer mappings', () async {
    final root = Directory.systemTemp.createTempSync('integration-wipe-');
    addTearDown(() => root.deleteSync(recursive: true));
    final database = createTestDatabase();
    addTearDown(database.close);
    final cache = IntegrationJsonCache(readRootDirectory: () async => root);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: <Override>[
          integrationJsonCacheProvider.overrideWithValue(cache),
          integrationAccountScopeProvider.overrideWithValue('account'),
        ],
      ),
    );
    addTearDown(container.dispose);
    final store = container.read(artistTopTrackMatchStoreProvider);
    await store.save('artist', {
      'seed': ArtistTopTrackMatchEntry.unmatched(checkedAt: DateTime.now()),
    }, generation: store.generation);
    final trendingStore = container.read(trendingMatchStoreProvider);
    await trendingStore.save(kTrendingMatchKey, {
      'seed': ArtistTopTrackMatchEntry.unmatched(checkedAt: DateTime.now()),
    }, generation: trendingStore.generation);
    expect(await trendingStore.load(kTrendingMatchKey), hasLength(1));
    await cache.write(DeezerCache.artistIdNamespace, 'mapping', {
      'id': 1,
    }, ttl: const Duration(days: 1));

    await container.read(clearIntegrationLibraryCacheProvider)();

    expect(await store.load('artist'), isEmpty);
    expect(await trendingStore.load(kTrendingMatchKey), isEmpty);
    expect(await cache.read(DeezerCache.artistIdNamespace, 'mapping'), isNull);
  });
}
