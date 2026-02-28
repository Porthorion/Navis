import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../../../helpers/test_database.dart';

void main() {
  test(
    'latest schema opens with expected user_version',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final pragmaRow = await database
          .customSelect('PRAGMA user_version;')
          .getSingle();

      expect(database.schemaVersion, 24);
      expect(pragmaRow.read<int>('user_version'), 24);
    },
    skip: !sqliteAvailable,
  );

  test(
    'latest schema creates app settings defaults',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final settings = await database.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.id, AppSettingsDao.primarySettingsId);
      expect(settings.wifiMaxBitRate, isNull);
      expect(settings.wifiFormat, isNull);
      expect(
        settings.cellularMaxBitRate,
        AppSettingsDao.defaultCellularBitRate,
      );
      expect(
        settings.cellularFormat,
        AppSettingsDao.defaultCellularFormat,
      );
      expect(settings.scrobbleEnabled, isTrue);
      expect(settings.gaplessEnabled, isTrue);
      expect(settings.skipSilenceEnabled, isFalse);
      expect(settings.showRadioPage, isTrue);
      expect(settings.showPlaylistsPage, isTrue);
      expect(settings.showArtistsPage, isTrue);
      expect(settings.showLikedPage, isTrue);
      expect(settings.equalizerEnabled, isFalse);
      expect(settings.equalizerBandGains, isNull);
      expect(settings.loudnessEnabled, isFalse);
      expect(settings.loudnessTargetGainDb, 0);
      expect(
        settings.rollingCacheBudgetMb,
        AppSettingsDao.defaultRollingCacheBudgetMb,
      );
      expect(settings.autoDownloadStarredOnWifi, isFalse);
      expect(settings.updateCheckEnabled, isTrue);
      expect(settings.updateChannel, 'stable');
    },
    skip: !sqliteAvailable,
  );

  test(
    'latest schema creates scrobble queue table',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final tableInfo = await database
          .customSelect("PRAGMA table_info('scrobble_queue');")
          .get();

      expect(tableInfo, isNotEmpty);
      final columns = tableInfo.map((row) => row.read<String>('name')).toSet();
      expect(
        columns,
        containsAll(<String>{
          'id',
          'song_id',
          'submission',
          'created_at',
          'next_attempt_at',
          'attempts',
          'expires_at',
          'session_key',
          'last_error',
        }),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'latest schema includes songs.created_at column',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      final tableInfo = await database
          .customSelect("PRAGMA table_info('songs');")
          .get();
      final columns = tableInfo.map((row) => row.read<String>('name')).toSet();

      expect(columns, contains('created_at'));
    },
    skip: !sqliteAvailable,
  );

  test(
    'backfillAlbumHydrationState marks albums with songs as hydrated',
    () async {
      final database = NavisDatabase(NativeDatabase.memory());
      addTearDown(database.close);

      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-with-song',
              name: 'Album With Song',
              songsHydrated: const Value(false),
            ),
          );
      await database
          .into(database.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-without-song',
              name: 'Album Without Song',
              songsHydrated: const Value(false),
            ),
          );
      await database
          .into(database.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-with-song'),
            ),
          );

      await database.backfillAlbumHydrationState();

      final rows = await database.select(database.albumsTable).get();
      final byId = {for (final row in rows) row.id: row};
      expect(byId['album-with-song']?.songsHydrated, isTrue);
      expect(byId['album-without-song']?.songsHydrated, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates representative v2 schema to latest and backfills critical fields',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase
          .into(seedDatabase.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-with-song',
              name: 'Album With Song',
              songsHydrated: const Value(true),
            ),
          );
      await seedDatabase
          .into(seedDatabase.albumsTable)
          .insert(
            AlbumsTableCompanion.insert(
              id: 'album-without-song',
              name: 'Album Without Song',
              songsHydrated: const Value(true),
            ),
          );
      await seedDatabase
          .into(seedDatabase.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 'song-legacy',
              title: 'Legacy Song',
              albumId: const Value('album-with-song'),
            ),
          );
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP INDEX IF EXISTS idx_albums_songs_hydrated;');
        raw.execute('DROP INDEX IF EXISTS idx_songs_created_at;');
        raw.execute('ALTER TABLE albums DROP COLUMN songs_hydrated;');
        raw.execute('ALTER TABLE songs DROP COLUMN created_at;');
        raw.execute('DROP TABLE IF EXISTS app_settings;');
        raw.execute('DROP TABLE IF EXISTS scrobble_queue;');
        raw.execute('DROP TABLE IF EXISTS star_sync_queue;');
        raw.execute('PRAGMA user_version = 2;');
      } finally {
        raw.dispose();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 24);

      final albums = await migrated.select(migrated.albumsTable).get();
      final albumsById = {for (final album in albums) album.id: album};
      expect(albumsById['album-with-song']?.songsHydrated, isTrue);
      expect(albumsById['album-without-song']?.songsHydrated, isFalse);

      final albumsInfo = await migrated
          .customSelect("PRAGMA table_info('albums');")
          .get();
      final albumColumns = albumsInfo
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(albumColumns, contains('synced_at'));

      final songsInfo = await migrated
          .customSelect("PRAGMA table_info('songs');")
          .get();
      final songColumns = songsInfo
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(songColumns, contains('created_at'));

      final settings = await migrated.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.gaplessEnabled, isTrue);
      expect(settings.skipSilenceEnabled, isFalse);
      expect(settings.showRadioPage, isTrue);
      expect(settings.showPlaylistsPage, isTrue);
      expect(settings.showArtistsPage, isTrue);
      expect(settings.showLikedPage, isTrue);
      expect(settings.equalizerEnabled, isFalse);
      expect(settings.equalizerBandGains, isNull);
      expect(settings.loudnessEnabled, isFalse);
      expect(settings.loudnessTargetGainDb, 0);
      expect(
        settings.rollingCacheBudgetMb,
        AppSettingsDao.defaultRollingCacheBudgetMb,
      );
      expect(settings.autoDownloadStarredOnWifi, isFalse);
    },
    skip: !sqliteAvailable,
  );
}
