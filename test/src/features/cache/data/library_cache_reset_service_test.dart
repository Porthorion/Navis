import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:navis/src/features/cache/data/cache_system_upgrade_service.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/features/cache/presentation/library_cache_reset_provider.dart';

import '../../../../helpers/test_database.dart';

final _package = PackageInfo(
  appName: 'Navis',
  packageName: 'navis',
  version: '1.4.3',
  buildNumber: '10403',
);

const _profile = ServerConfigModel(
  id: 1,
  url: 'https://example.test',
  username: 'fixture',
  password: '',
  apiVersion: '1.16.1',
);

Future<void> _saveProfile(NavisDatabase database) =>
    database.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: _profile.url,
        username: _profile.username,
        apiVersion: _profile.apiVersion,
      ),
    );

void main() {
  for (final (version, epoch) in [
    ('1.4.3', 1004),
    ('1.4.99+10499', 1004),
    ('1.5.0', 1005),
    ('2.0.0', 2000),
  ]) {
    test('cache epoch for $version is $epoch', () {
      expect(CacheSystemUpgradeService.epochFromVersion(version), epoch);
    });
  }
  test('invalid cache epochs fail parsing', () {
    for (final version in ['unknown', '1.4', '-1.4.0', '1.1000.0']) {
      expect(
        () => CacheSystemUpgradeService.epochFromVersion(version),
        throwsFormatException,
      );
    }
  });

  for (final (stored, required) in <(int?, bool)>[
    (1004, false),
    (1003, true),
    (1005, true),
    (3, true),
    (0, true),
    (null, true),
  ]) {
    test(
      'committed catalog with epoch $stored needs reset: $required',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        if (stored != null) {
          await database.cacheSystemStateDao.markVersion(stored);
        }
        final service = CacheSystemUpgradeService(
          database: database,
          cacheResetService: LibraryCacheResetService(database: database),
          triggerFullLibraryScan: () async => true,
          currentEpoch: () async => 1004,
          hasCommittedCatalog: () async => true,
        );
        expect(await service.needsReset(), required);
      },
      skip: !sqliteAvailable,
    );
  }

  for (final stored in <int?>[null, 3, 1003]) {
    test('never-synced profile adopts epoch from $stored', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _saveProfile(database);
      if (stored != null) {
        await database.cacheSystemStateDao.markVersion(stored);
      }
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            serverConfigStateProvider.overrideWithValue(
              const AsyncData(_profile),
            ),
            packageInfoProvider.overrideWith((ref) async => _package),
          ],
        ),
      );
      addTearDown(container.dispose);
      expect(
        await container.read(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
      expect(await database.cacheSystemStateDao.getVersion(), 1004);
      expect(
        await container.refresh(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
    }, skip: !sqliteAvailable);
  }

  test(
    'partial usable catalog renews and refreshes after acknowledgement',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _saveProfile(database);
      await database.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          currentGeneration: const Value(1),
          initialCatalogUsableAt: Value(DateTime.now()),
        ),
      );
      await database.cacheSystemStateDao.markVersion(1003);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            serverConfigStateProvider.overrideWithValue(
              const AsyncData(_profile),
            ),
            packageInfoProvider.overrideWith((ref) async => _package),
          ],
        ),
      );
      addTearDown(container.dispose);
      expect(
        await container.read(cacheSystemUpgradeNeededProvider.future),
        isTrue,
      );
      expect(container.read(cacheSystemUpgradeRequiredProvider), isTrue);
      await container
          .read(cacheSystemUpgradeServiceProvider)
          .markCurrentVersionAfterSuccessfulScan();
      expect(
        await container.refresh(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );

  test('package metadata loading holds routing until it resolves', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _saveProfile(database);
    final package = Completer<PackageInfo>();
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: withTestDatabase(
        database,
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(_profile),
          ),
          packageInfoProvider.overrideWith((ref) => package.future),
        ],
      ),
    );
    addTearDown(container.dispose);
    expect(container.read(cacheSystemUpgradeRequiredProvider), isNull);
    package.complete(_package);
    expect(
      await container.read(cacheSystemUpgradeNeededProvider.future),
      isFalse,
    );
    expect(container.read(cacheSystemUpgradeRequiredProvider), isFalse);
  }, skip: !sqliteAvailable);

  test(
    'package metadata errors skip renewal without changing its marker',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _saveProfile(database);
      await database.cacheSystemStateDao.markVersion(3);
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            serverConfigStateProvider.overrideWithValue(
              const AsyncData(_profile),
            ),
            packageInfoProvider.overrideWith(
              (ref) => throw StateError('Package unavailable'),
            ),
          ],
        ),
      );
      addTearDown(container.dispose);
      expect(
        await container.read(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
      expect(container.read(cacheSystemUpgradeRequiredProvider), isFalse);
      expect(await database.cacheSystemStateDao.getVersion(), 3);
    },
    skip: !sqliteAvailable,
  );

  test(
    'stalled package metadata skips renewal without changing its marker',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _saveProfile(database);
      await database.cacheSystemStateDao.markVersion(3);
      final package = Completer<PackageInfo>();
      final container = ProviderContainer(
        overrides: withTestDatabase(
          database,
          overrides: [
            serverConfigStateProvider.overrideWithValue(
              const AsyncData(_profile),
            ),
            packageInfoProvider.overrideWith((ref) => package.future),
          ],
        ),
      );
      addTearDown(container.dispose);
      expect(
        await container.read(cacheSystemUpgradeNeededProvider.future),
        isFalse,
      );
      expect(container.read(libraryCacheEpochProvider).requireValue, isNull);
      expect(container.read(cacheSystemUpgradeRequiredProvider), isFalse);
      expect(await database.cacheSystemStateDao.getVersion(), 3);
      package.complete(_package);
    },
    skip: !sqliteAvailable,
  );

  test('marker read errors keep renewal required', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    await _saveProfile(database);
    await database.customStatement('DROP TABLE cache_system_state');
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: withTestDatabase(
        database,
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(_profile),
          ),
          packageInfoProvider.overrideWith((ref) async => _package),
        ],
      ),
    );
    addTearDown(container.dispose);
    await expectLater(
      container.read(cacheSystemUpgradeNeededProvider.future),
      throwsA(isA<Exception>()),
    );
    expect(container.read(cacheSystemUpgradeRequiredProvider), isTrue);
  }, skip: !sqliteAvailable);

  for (final succeeds in [false, true]) {
    test('cache renewal stamps only a successful scan: $succeeds', () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      await _saveProfile(database);
      await database.cacheSystemStateDao.markVersion(3);
      var scanCalls = 0;
      final service = CacheSystemUpgradeService(
        database: database,
        cacheResetService: LibraryCacheResetService(database: database),
        currentEpoch: () async => 1004,
        hasCommittedCatalog: () async => true,
        triggerFullLibraryScan: () async {
          scanCalls++;
          return succeeds;
        },
      );
      if (succeeds) {
        await service.resetAndMarkCurrent();
      } else {
        await expectLater(service.resetAndMarkCurrent(), throwsStateError);
      }
      expect(scanCalls, 1);
      expect(
        await database.cacheSystemStateDao.getVersion(),
        succeeds ? 1004 : 3,
      );
      expect(await service.needsReset(), !succeeds);
    }, skip: !sqliteAvailable);
  }

  test(
    'reset removes recoverable cache and metadata but keeps downloads',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final directory = await Directory.systemTemp.createTemp(
        'navis_cache_reset_',
      );
      addTearDown(() async {
        await database.close();
        if (directory.existsSync()) {
          await directory.delete(recursive: true);
        }
      });

      final rollingPath = '${directory.path}/rolling.mp3';
      final downloadPath = '${directory.path}/download.mp3';
      await File(rollingPath).writeAsString('rolling');
      await File('$rollingPath.part').writeAsString('part');
      await File(downloadPath).writeAsString('download');
      var clearCoverArtCalls = 0;

      await database
          .into(database.artistsTable)
          .insert(ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist'));
      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album',
              artistId: const Value('artist-1'),
            ),
          );
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song',
              albumId: const Value('album-1'),
              artistId: const Value('artist-1'),
            ),
          );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'song-1',
          filePath: rollingPath,
          fileSize: 7,
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.rolling,
          downloadStatus: DownloadStatus.complete,
        ),
      );
      await database.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'download-1',
          filePath: downloadPath,
          fileSize: 8,
          format: 'mp3',
          lastAccessedAt: DateTime.now(),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
        ),
      );

      await LibraryCacheResetService(
        database: database,
        clearCoverArt: () async => clearCoverArtCalls += 1,
      ).reset();

      expect(File(rollingPath).existsSync(), isFalse);
      expect(File('$rollingPath.part').existsSync(), isFalse);
      expect(File(downloadPath).existsSync(), isTrue);
      expect(await database.cacheDao.getCachedTracks(), hasLength(1));
      expect(
        (await database.cacheDao.getCachedTracks()).single.songId,
        'download-1',
      );
      expect(await database.select(database.songsTable).get(), isEmpty);
      expect(await database.select(database.albumsTable).get(), isEmpty);
      expect(await database.select(database.artistsTable).get(), isEmpty);
      expect(clearCoverArtCalls, 1);
    },
    skip: !sqliteAvailable,
  );
}
