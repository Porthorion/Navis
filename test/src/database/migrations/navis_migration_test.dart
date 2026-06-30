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
  test('latest schema opens with expected user_version', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final pragmaRow = await database
        .customSelect('PRAGMA user_version;')
        .getSingle();

    expect(database.schemaVersion, 53);
    expect(pragmaRow.read<int>('user_version'), 53);
  }, skip: !sqliteAvailable);

  test('latest schema creates app settings defaults', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final settings = await database.appSettingsDao.getSettings();
    expect(settings, isNotNull);
    expect(settings!.id, AppSettingsDao.primarySettingsId);
    expect(settings.wifiMaxBitRate, isNull);
    expect(settings.wifiFormat, isNull);
    expect(settings.cellularMaxBitRate, AppSettingsDao.defaultCellularBitRate);
    expect(settings.cellularFormat, AppSettingsDao.defaultCellularFormat);
    expect(settings.cachedPlaybackFirst, isFalse);
    expect(settings.scrobbleEnabled, isTrue);
    expect(settings.gaplessEnabled, isTrue);
    expect(settings.skipSilenceEnabled, isFalse);
    expect(settings.showAlbumsPage, isTrue);
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
    expect(settings.customDownloadFolderEnabled, isFalse);
    expect(settings.customDownloadFolderPath, isNull);
    expect(settings.useLrclib, isTrue);
    expect(settings.updateCheckEnabled, isTrue);
    expect(settings.updateChannel, 'stable');
    expect(settings.homeDensity, 'comfortable');
    expect(settings.matchFlowEnabled, isFalse);
    final groupListening = await database.appSettingsDao
        .getGroupListeningSettings();
    final columns = await database
        .customSelect("PRAGMA table_info('app_settings');")
        .get();
    final columnNames = columns.map((row) => row.read<String>('name')).toSet();
    expect(
      columnNames,
      containsAll(<String>{
        'group_listening_enabled',
        'voyage_server_url',
        'voyage_display_name',
        'voyage_device_label',
        'voyage_auto_follow_host',
        'match_flow_enabled',
        'custom_download_folder_enabled',
        'custom_download_folder_path',
        'cached_playback_first',
        'listen_brainz_user_name',
      }),
    );
    expect(groupListening.groupListeningEnabled, isFalse);
    expect(groupListening.voyageServerUrl, isNull);
    expect(groupListening.voyageDisplayName, isNull);
    expect(groupListening.voyageDeviceLabel, isNull);
    expect(groupListening.voyageAutoFollowHost, isTrue);

    final songColumns = await database
        .customSelect("PRAGMA table_info('songs');")
        .get();
    expect(
      songColumns.map((row) => row.read<String>('name')).toSet(),
      contains('recording_mbid'),
    );
    final feedbackQueueColumns = await database
        .customSelect("PRAGMA table_info('listenbrainz_feedback_queue');")
        .get();
    expect(feedbackQueueColumns, isNotEmpty);
  }, skip: !sqliteAvailable);

  test(
    'migrates v44 schema to v45 with cached playback setting',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v45_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute(
          'ALTER TABLE app_settings DROP COLUMN cached_playback_first;',
        );
        raw.execute('PRAGMA user_version = 44;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 53);

      final settingsInfo = await migrated
          .customSelect("PRAGMA table_info('app_settings');")
          .get();
      final settingColumns = settingsInfo
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(settingColumns, contains('cached_playback_first'));

      final settings = await migrated.appSettingsDao.getSettings();
      expect(settings?.cachedPlaybackFirst, isFalse);
    },
    skip: !sqliteAvailable,
  );

  test('latest schema creates scrobble queue table', () async {
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
  }, skip: !sqliteAvailable);

  test(
    'migrates v45 scrobble queue to provider-aware uniqueness',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_scrobble_queue_v46_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase
          .into(seedDatabase.songsTable)
          .insert(SongsTableCompanion.insert(id: 'song-1', title: 'Song 1'));
      await seedDatabase.close();

      final createdAt = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;
      final expiresAt = DateTime.utc(2026, 1, 2).millisecondsSinceEpoch;
      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP TABLE scrobble_queue;');
        raw.execute('''
CREATE TABLE scrobble_queue (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  song_id TEXT NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
  submission INTEGER NOT NULL CHECK (submission IN (0, 1)),
  created_at INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL,
  session_key TEXT NOT NULL,
  last_error TEXT NULL,
  UNIQUE (song_id, submission, session_key)
);
''');
        raw.execute(
          'INSERT INTO scrobble_queue (song_id, submission, created_at, next_attempt_at, expires_at, session_key) '
          "VALUES ('song-1', 1, $createdAt, $createdAt, $expiresAt, 'session-1');",
        );
        raw.execute('PRAGMA user_version = 45;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 53);

      final now = DateTime.utc(2026, 1, 1, 1);
      await migrated.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'lastfm',
        submission: true,
        sessionKey: 'session-1',
        trackTitle: 'Song 1',
        artistName: 'Artist',
        createdAt: now,
        nextAttemptAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );
      await migrated.scrobbleDao.enqueue(
        songId: 'song-1',
        provider: 'listenbrainz',
        submission: true,
        sessionKey: 'session-1',
        trackTitle: 'Song 1',
        artistName: 'Artist',
        createdAt: now,
        nextAttemptAt: now,
        expiresAt: now.add(const Duration(days: 1)),
      );

      final rows = await migrated.select(migrated.scrobbleQueueTable).get();
      expect(rows.map((row) => row.provider).toSet(), {
        'subsonic',
        'lastfm',
        'listenbrainz',
      });
    },
    skip: !sqliteAvailable,
  );

  test('latest schema includes local-only song columns', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final tableInfo = await database
        .customSelect("PRAGMA table_info('songs');")
        .get();
    final columns = tableInfo.map((row) => row.read<String>('name')).toSet();

    expect(columns, contains('created_at'));
    expect(columns, contains('server_deleted_at'));
  }, skip: !sqliteAvailable);

  test(
    'migrates v43 schema to v44 with custom download folder settings',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v44_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute(
          'ALTER TABLE app_settings DROP COLUMN custom_download_folder_enabled;',
        );
        raw.execute(
          'ALTER TABLE app_settings DROP COLUMN custom_download_folder_path;',
        );
        raw.execute('PRAGMA user_version = 43;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 53);

      final settingsInfo = await migrated
          .customSelect("PRAGMA table_info('app_settings');")
          .get();
      final settingColumns = settingsInfo
          .map((row) => row.read<String>('name'))
          .toSet();
      expect(settingColumns, contains('custom_download_folder_enabled'));
      expect(settingColumns, contains('custom_download_folder_path'));
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
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 53);

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
      expect(
        songColumns,
        containsAll(<String>['created_at', 'server_deleted_at']),
      );

      final settings = await migrated.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.gaplessEnabled, isTrue);
      expect(settings.cachedPlaybackFirst, isFalse);
      expect(settings.skipSilenceEnabled, isFalse);
      expect(settings.showAlbumsPage, isTrue);
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
      expect(settings.customDownloadFolderEnabled, isFalse);
      expect(settings.customDownloadFolderPath, isNull);
      expect(settings.albumGridDensity, isNull);
      expect(settings.coverArtShape, 'square');
      expect(settings.nowPlayingArtShape, 'rounded');
      expect(settings.artistCardShape, 'circle');
      expect(settings.artistViewMode, 'grid');
      expect(settings.homeDensity, 'comfortable');
      expect(settings.homeSectionOrder, isNull);
      expect(settings.homeSectionsHidden, isNull);
      expect(settings.useLrclib, isTrue);
      expect(settings.matchFlowEnabled, isFalse);
      final tables = await migrated
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
          .get();
      final tableNames = tables.map((row) => row.read<String>('name')).toSet();
      expect(
        tableNames,
        containsAll(<String>['match_flows', 'match_flow_songs']),
      );
      final indexes = await migrated
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index';")
          .get();
      final indexNames = indexes.map((row) => row.read<String>('name')).toSet();
      expect(indexNames, contains('idx_match_flow_unique_master'));
      final groupListening = await migrated.appSettingsDao
          .getGroupListeningSettings();
      expect(groupListening.groupListeningEnabled, isFalse);
      expect(groupListening.voyageServerUrl, isNull);
      expect(groupListening.voyageDisplayName, isNull);
      expect(groupListening.voyageDeviceLabel, isNull);
      expect(groupListening.voyageAutoFollowHost, isTrue);
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v52 schema to v53 clearing retired Listen Together settings',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v53_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.appSettingsDao.getSettings();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('''
UPDATE app_settings
SET group_listening_enabled = 1,
    voyage_server_url = 'https://voyage.example.com',
    voyage_display_name = 'Living Room',
    voyage_device_label = 'Pixel Tablet',
    voyage_auto_follow_host = 0,
    custom_voyage_servers = '[{"label":"Custom","url":"https://custom.example.com"}]';
''');
        raw.execute('PRAGMA user_version = 52;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final versionRow = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(versionRow.read<int>('user_version'), 53);

      final settings = await migrated.appSettingsDao.getSettings();
      expect(settings?.customVoyageServers, isNull);

      final groupListening = await migrated.appSettingsDao
          .getGroupListeningSettings();
      expect(groupListening.groupListeningEnabled, isFalse);
      expect(groupListening.voyageServerUrl, isNull);
      expect(groupListening.voyageDisplayName, isNull);
      expect(groupListening.voyageDeviceLabel, isNull);
      expect(groupListening.voyageAutoFollowHost, isTrue);
    },
    skip: !sqliteAvailable,
  );
}
