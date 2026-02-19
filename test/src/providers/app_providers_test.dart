import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

void main() {
  group('app providers', () {
    test('subsonicApiProvider returns null when server config missing', () {
      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(subsonicApiProvider), isNull);
    });

    test(
      'network and streaming quality providers resolve cellular profile',
      () async {
        final container = ProviderContainer(
          overrides: [
            networkTypeProvider.overrideWith((_) => NetworkType.cellular),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(networkTypeProvider), NetworkType.cellular);
        expect(container.read(activeStreamingQualityProvider).maxBitRate, 320);
      },
    );

    test(
      'artistsProvider streams rows from drift database',
      () async {
        final database = NavisDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'a1', name: 'Artist 1'),
          ],
        );

        final artists = await container.read(artistsProvider.future);
        expect(artists.single.id, 'a1');
      },
      skip: !_sqliteAvailable,
    );

    test('subsonicApiProvider builds client when server config exists', () {
      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(subsonicApiProvider), isNotNull);
    });
  });
}
