import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_source.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;

class _CacheManager extends Fake implements CacheManager;

void main() {
  final api = SubsonicApiClient(
    baseUrl: 'https://example.test',
    authConfig: const SubsonicAuthConfig(
      username: 'test',
      password: 'test',
      apiVersion: '1.16.1',
    ),
    enableLogging: false,
  );
  test(
    'downloaded artwork resolves from the permanent store offline',
    () async {
      final support = Directory.systemTemp.createTempSync('cover_source');
      addTearDown(() => support.deleteSync(recursive: true));
      final file = File(
        p.join(support.path, 'artwork', 'permanent', 'cover.png'),
      );
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync([1]);
      final container = ProviderContainer(
        overrides: [
          subsonicApiProvider.overrideWithValue(null),
          coverArtCacheManagerProvider.overrideWithValue(_CacheManager()),
          permanentArtworkStoreProvider.overrideWithValue(
            PermanentArtworkStore(
              readApplicationSupportDirectory: () async => support,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      for (final revision in [0, 2]) {
        final image = await container.read(
          coverArtImageSourceProvider(('cover', 600, revision)).future,
        );
        expect(image, isA<FileImage>());
        expect((image! as FileImage).file.path, file.path);
      }
    },
  );

  test('refresh revision selects the revisioned key while connected', () {
    final permanent = File('cover.png');
    final manager = _CacheManager();
    expect(
      coverArtImageProviderFor(
        coverArtId: 'cover',
        size: 600,
        api: api,
        cacheManager: manager,
        permanentFile: permanent,
      ),
      isA<FileImage>(),
    );
    final image = coverArtImageProviderFor(
      coverArtId: 'cover',
      size: 600,
      api: api,
      cacheManager: manager,
      permanentFile: permanent,
      revision: 2,
    );
    expect(image, isA<CachedNetworkImageProvider>());
    expect(
      (image! as CachedNetworkImageProvider).cacheKey,
      coverArtImageCacheKey('cover', 600, revision: 2),
    );
    expect((image as CachedNetworkImageProvider).cacheManager, same(manager));
  });
}
