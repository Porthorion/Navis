import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../helpers/test_database.dart';

void main() {
  test(
    'v77 catalog readiness migrates separately from full freshness',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_catalog_readiness_migration_',
      );
      final file = File(p.join(directory.path, 'fixture.sqlite'));
      final seed = createTestDatabase(file: file);
      await seed.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'fixture',
          apiVersion: '1.16.1',
        ),
      );
      await seed.librarySyncDao.getOrCreateState(1);
      await seed.close();
      final raw = sqlite3.open(file.path);
      raw.execute(
        'ALTER TABLE library_sync_state DROP COLUMN initial_catalog_usable_at',
      );
      raw.execute('PRAGMA user_version = 77');
      raw.dispose();
      final migrated = createTestDatabase(file: file);
      addTearDown(() async {
        await migrated.close();
        await directory.delete(recursive: true);
      });
      final state = await migrated.librarySyncDao.getOrCreateState(1);
      expect(state.initialCatalogUsableAt, isNull);
      expect(state.lastCatalogSyncedAt, isNull);
      await migrated.librarySyncDao.writeState(
        LibrarySyncStateTableCompanion(
          serverId: const Value(1),
          initialCatalogUsableAt: Value(DateTime.utc(2026, 9, 20)),
        ),
      );
      final ready = await migrated.librarySyncDao.getOrCreateState(1);
      expect(ready.initialCatalogUsableAt, isNotNull);
      expect(ready.lastCatalogSyncedAt, isNull);
      expect(migrated.schemaVersion, 78);
    },
  );

  test('v76 attempts survive migration with unknown telemetry', () async {
    final directory = await Directory.systemTemp.createTemp(
      'navis_attempt_migration_',
    );
    final file = File(p.join(directory.path, 'fixture.sqlite'));
    final seed = createTestDatabase(file: file);
    await seed.serverDao.saveServer(
      ServerConfigTableCompanion.insert(
        url: 'https://example.test',
        username: 'fixture',
        apiVersion: '1.16.1',
      ),
    );
    final now = DateTime.utc(2026, 9, 19);
    final requestId = await seed
        .into(seed.librarySyncRunRequestTable)
        .insert(
          LibrarySyncRunRequestTableCompanion.insert(
            serverId: 1,
            contractVersion: 1,
            origin: 0,
            intent: 0,
            targetKind: 0,
            networkGrant: 0,
            planKind: 0,
            priority: 1,
            coalescingKey: 'fixture',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final attempt = await seed.librarySyncDao.beginSyncRunAttempt(
      requestId: requestId,
      androidWorker: true,
      now: now,
    );
    await seed.close();
    final raw = sqlite3.open(file.path);
    raw.execute(
      'ALTER TABLE library_sync_run_attempt DROP COLUMN telemetry_json',
    );
    raw.execute('PRAGMA user_version = 76');
    raw.dispose();
    final migrated = createTestDatabase(file: file);
    addTearDown(() async {
      await migrated.close();
      await directory.delete(recursive: true);
    });
    final rows = await migrated.librarySyncDao.getRecentSyncAttempts(1);
    expect(rows.single.id, attempt.id);
    expect(rows.single.requestId, requestId);
    expect(rows.single.status, 0);
    expect(rows.single.ownerKind, 1);
    expect(rows.single.telemetryJson, isNull);
    await migrated.librarySyncDao.writeAttemptTelemetry(attempt.id, {
      'version': 1,
    });
    expect(
      (await migrated.librarySyncDao.getRecentSyncAttempts(1))
          .single
          .telemetryJson,
      '{"version":1}',
    );
    expect(migrated.schemaVersion, 78);
    expect(
      await migrated.customSelect('PRAGMA foreign_key_check').get(),
      isEmpty,
    );
  });

  test(
    'v75 playlist migration preserves rows and allows repeated tracks',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_playlist_migration_',
      );
      final file = File(p.join(directory.path, 'fixture.sqlite'));
      final seed = createTestDatabase(file: file);
      await seed.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's', title: 'Song'),
      ]);
      await seed.playlistDao.upsertPlaylists([
        PlaylistsTableCompanion.insert(id: 'p', name: 'Playlist'),
      ]);
      await seed.close();
      final raw = sqlite3.open(file.path);
      raw.execute('DROP TABLE annotation_dispatch_lease');
      raw.execute('DROP TABLE playlist_songs');
      raw.execute(
        'CREATE TABLE playlist_songs (playlist_id TEXT NOT NULL REFERENCES playlists(id), '
        'song_id TEXT NOT NULL REFERENCES songs(id), sort_order INTEGER NOT NULL, PRIMARY KEY (playlist_id, song_id))',
      );
      raw.execute("INSERT INTO playlist_songs VALUES ('p','s',4)");
      raw.execute('PRAGMA user_version = 75');
      raw.dispose();
      final migrated = createTestDatabase(file: file);
      addTearDown(() async {
        await migrated.close();
        await directory.delete(recursive: true);
      });
      expect(
        await migrated.playlistDao.watchPlaylistSongs('p').first,
        hasLength(1),
      );
      await migrated
          .into(migrated.playlistSongsTable)
          .insert(
            PlaylistSongsTableCompanion.insert(
              playlistId: 'p',
              songId: 's',
              sortOrder: 1,
            ),
          );
      expect(
        await migrated.playlistDao.watchPlaylistSongs('p').first,
        hasLength(2),
      );
      expect(
        await migrated.starSyncDao.acquireDispatchLease(
          'fixture',
          DateTime.now(),
        ),
        isTrue,
      );
      expect(
        await migrated.customSelect('PRAGMA foreign_key_check').get(),
        isEmpty,
      );
    },
  );
  test(
    'v74 adds unknown verification age without claiming old songs are fresh',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_verification_migration_',
      );
      final file = File(p.join(directory.path, 'fixture.sqlite'));
      final seed = createTestDatabase(file: file);
      await seed.libraryDao.upsertAlbums([
        AlbumsTableCompanion.insert(
          id: 'kept',
          name: 'Kept',
          songsHydrated: const Value(true),
        ),
      ]);
      await seed.close();
      final raw = sqlite3.open(file.path);
      raw.execute('ALTER TABLE albums DROP COLUMN songs_verified_at');
      raw.execute('PRAGMA user_version = 74');
      raw.dispose();
      final migrated = createTestDatabase(file: file);
      addTearDown(() async {
        await migrated.close();
        await directory.delete(recursive: true);
      });
      final album = (await migrated.libraryDao.getAlbumById('kept'))!;
      expect(album.songsHydrated, isTrue);
      expect(album.songsVerifiedAt, isNull);
      expect(migrated.schemaVersion, 78);
    },
  );
  test(
    'v73 annotation outbox retains pending stars and adds durable retry fields',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis_annotation_migration_',
      );
      final file = File(p.join(directory.path, 'fixture.sqlite'));
      final seed = createTestDatabase(file: file);
      await seed.starSyncDao.queueStarAction(
        itemId: 'a',
        itemType: 'album',
        action: 'unstar',
      );
      await seed.close();
      final raw = sqlite3.open(file.path);
      for (final column in [
        'operation',
        'attempt_count',
        'not_before',
        'last_error_type',
      ]) {
        raw.execute('ALTER TABLE star_sync_queue DROP COLUMN $column');
      }
      raw.execute('PRAGMA user_version = 73');
      raw.dispose();
      final migrated = createTestDatabase(file: file);
      addTearDown(() async {
        await migrated.close();
        await directory.delete(recursive: true);
      });
      final pending = (await migrated.starSyncDao.getPendingActions()).single;
      expect(pending.itemId, 'a');
      expect(pending.action, 'unstar');
      expect(pending.operation, 'star');
      expect(pending.attemptCount, 0);
      expect(pending.notBefore, isNull);
      expect(migrated.schemaVersion, 78);
    },
  );
  test('latest schema opens with expected user_version', () async {
    final database = NavisDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    final pragmaRow = await database
        .customSelect('PRAGMA user_version;')
        .getSingle();

    expect(database.schemaVersion, 78);
    expect(pragmaRow.read<int>('user_version'), 78);
  }, skip: !sqliteAvailable);

  test('migrates v70 profiles to typed sync lifecycle storage', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v71_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
    await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
    await seedDatabase.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute('DROP TABLE library_sync_run_outcome;');
      raw.execute('DROP TABLE library_sync_run_attempt;');
      raw.execute('DROP TABLE library_sync_run_request;');
      raw.execute('DROP TABLE library_sync_provider_profile;');
      raw.execute('DROP TABLE library_sync_repair_session;');
      raw.execute('PRAGMA user_version = 70;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    expect(migrated.schemaVersion, 78);
    final tables = await migrated
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
        .get();
    expect(
      tables.map((row) => row.read<String>('name')).toSet(),
      containsAll(<String>{
        'library_sync_run_request',
        'library_sync_run_attempt',
        'library_sync_run_outcome',
        'library_sync_provider_profile',
        'library_sync_repair_session',
      }),
    );
  }, skip: !sqliteAvailable);

  test('migrates v71 candidates with a Recently Added rank', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v72_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
    await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
    await seedDatabase.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute(
        'ALTER TABLE library_sync_candidate_albums '
        'DROP COLUMN recently_added_rank;',
      );
      raw.execute('PRAGMA user_version = 71;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    final columns = await migrated
        .customSelect("PRAGMA table_info('library_sync_candidate_albums');")
        .get();
    expect(migrated.schemaVersion, 78);
    expect(
      columns.map((row) => row.read<String>('name')),
      contains('recently_added_rank'),
    );
  }, skip: !sqliteAvailable);

  test('migrates v72 remote-prefixed rows out of the local catalog', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v73_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
    await seedDatabase.libraryDao.upsertArtists(<ArtistsTableCompanion>[
      ArtistsTableCompanion.insert(id: 'ext-artist', name: 'Remote Artist'),
    ]);
    await seedDatabase.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(
        id: 'ext-album',
        name: 'Remote Album',
        artistId: const Value('ext-artist'),
      ),
    ]);
    await seedDatabase.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'remote-song',
        title: 'Remote Song',
        albumId: const Value('ext-album'),
        artistId: const Value('ext-artist'),
      ),
    ]);
    await seedDatabase.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute('PRAGMA user_version = 72;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    expect(migrated.schemaVersion, 78);
    expect(
      (await migrated.libraryDao.getArtistById('ext-artist'))?.isExternal,
      isTrue,
    );
    expect(
      (await migrated.libraryDao.getAlbumById('ext-album'))?.isExternal,
      isTrue,
    );
    expect(
      (await migrated.libraryDao.getSongById('remote-song'))?.isExternal,
      isTrue,
    );
    expect(await migrated.libraryDao.watchAllAlbums().first, isEmpty);
  }, skip: !sqliteAvailable);

  test(
    'migrates v65 profiles with a pending cache-system reset',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v66_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP TABLE cache_system_state;');
        raw.execute('PRAGMA user_version = 65;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final version = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      final marker = await migrated
          .customSelect('SELECT * FROM cache_system_state;')
          .get();
      expect(version.read<int>('user_version'), 78);
      expect(marker, isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test('migrates v69 albums with a newest-feed Recently Added rank', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v70_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
    await seedDatabase.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
      AlbumsTableCompanion.insert(id: 'album-1', name: 'Album 1'),
    ]);
    await seedDatabase.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute('ALTER TABLE albums DROP COLUMN recently_added_rank;');
      raw.execute('PRAGMA user_version = 69;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    final version = await migrated
        .customSelect('PRAGMA user_version;')
        .getSingle();
    final columns = await migrated
        .customSelect("PRAGMA table_info('albums');")
        .get();

    expect(version.read<int>('user_version'), 78);
    expect(
      columns.map((row) => row.read<String>('name')),
      contains('recently_added_rank'),
    );
    expect(
      (await migrated.libraryDao.getAlbumById('album-1'))?.recentlyAddedRank,
      isNull,
    );
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
    expect(settings.customDownloadFolderStorageKind, 'filesystem');
    expect(settings.useLrclib, isTrue);
    expect(settings.updateCheckEnabled, isTrue);
    expect(settings.updateChannel, 'stable');
    expect(settings.homeDensity, 'comfortable');
    expect(settings.matchFlowEnabled, isFalse);
    expect(settings.onboardingVersion, 0);
    expect(settings.albumQueueEnabled, isTrue);
    expect(settings.likedQueueEnabled, isTrue);
    expect(settings.desktopPlaybackVolume, 1);
    expect(settings.desktopLastAudibleVolume, 1);
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
        'custom_download_folder_storage_kind',
        'cached_playback_first',
        'listen_brainz_user_name',
        'desktop_playback_volume',
        'desktop_last_audible_volume',
        'onboarding_version',
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
    final cachedTrackColumns = await database
        .customSelect("PRAGMA table_info('cached_tracks');")
        .get();
    expect(
      cachedTrackColumns.map((row) => row.read<String>('name')).toSet(),
      contains('storage_kind'),
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
      expect(versionRow.read<int>('user_version'), 78);

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
      expect(versionRow.read<int>('user_version'), 78);

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
      expect(versionRow.read<int>('user_version'), 78);

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
      expect(versionRow.read<int>('user_version'), 78);

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
      expect(versionRow.read<int>('user_version'), 78);

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

  test(
    'migrates v53 schema to v54 with canonical provenance and aliases',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v54_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.libraryDao.upsertArtists(
        <ArtistsTableCompanion>[
          ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
        ],
      );
      await seedDatabase.libraryDao.upsertAlbums(
        <AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            artistId: const Value('artist-1'),
          ),
        ],
      );
      await seedDatabase.libraryDao.upsertSongs(
        <SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Song 1',
            albumId: const Value('album-1'),
            artistId: const Value('artist-1'),
          ),
        ],
      );
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP INDEX IF EXISTS idx_artists_provisional;');
        raw.execute('DROP INDEX IF EXISTS idx_albums_provisional;');
        raw.execute('DROP INDEX IF EXISTS idx_songs_provisional;');
        raw.execute(
          'DROP INDEX IF EXISTS idx_song_identity_aliases_canonical;',
        );
        raw.execute('DROP TABLE IF EXISTS song_identity_aliases;');
        raw.execute('ALTER TABLE artists DROP COLUMN is_provisional;');
        raw.execute('ALTER TABLE albums DROP COLUMN is_provisional;');
        raw.execute('ALTER TABLE songs DROP COLUMN is_provisional;');
        raw.execute('PRAGMA user_version = 53;');
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
      expect(versionRow.read<int>('user_version'), 78);

      for (final table in <String>['artists', 'albums', 'songs']) {
        final columns = await migrated
            .customSelect("PRAGMA table_info('$table');")
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          contains('is_provisional'),
        );
      }
      final aliasTable = await migrated
          .customSelect(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'song_identity_aliases';",
          )
          .get();
      expect(aliasTable, isNotEmpty);

      expect(
        (await migrated.libraryDao.getArtistById('artist-1'))?.isProvisional,
        isFalse,
      );
      expect(
        (await migrated.libraryDao.getAlbumById('album-1'))?.isProvisional,
        isFalse,
      );
      expect(
        (await migrated.libraryDao.getSongById('song-1'))?.isProvisional,
        isFalse,
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v54 sync state and catalog generations to v55',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v55_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final checkedAt = DateTime.utc(2026, 7, 1, 12);

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://music.example.test',
          username: 'listener',
          apiVersion: '1.16.1',
          capabilities: Value(
            '{"navis":{"libraryIndexesCursor":"${checkedAt.toIso8601String()}",'
            '"libraryIndexesFingerprint":"artist-1",'
            '"bulkSongSearchWildcardQuery":"*",'
            '"libraryPendingIndexesOffset":3}}',
          ),
          lastSynced: Value(checkedAt),
        ),
      );
      await seedDatabase.libraryDao.upsertArtists([
        ArtistsTableCompanion.insert(id: 'artist-1', name: 'Artist 1'),
      ]);
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP INDEX IF EXISTS idx_artists_catalog_generation;');
        raw.execute('DROP INDEX IF EXISTS idx_albums_catalog_generation;');
        raw.execute('DROP INDEX IF EXISTS idx_songs_catalog_generation;');
        raw.execute('DROP INDEX IF EXISTS idx_network_usage_operation;');
        raw.execute('DROP INDEX IF EXISTS idx_library_sync_work_due;');
        raw.execute('DROP TABLE IF EXISTS library_sync_work;');
        raw.execute('DROP TABLE IF EXISTS library_sync_state;');
        raw.execute('ALTER TABLE artists DROP COLUMN catalog_generation;');
        raw.execute('ALTER TABLE albums DROP COLUMN catalog_generation;');
        raw.execute('ALTER TABLE songs DROP COLUMN catalog_generation;');
        raw.execute('ALTER TABLE network_usage_events DROP COLUMN operation;');
        raw.execute(
          'ALTER TABLE server_config RENAME TO server_config_legacy;',
        );
        raw.execute('''
          CREATE TABLE server_config (
            id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
            name TEXT NULL,
            url TEXT NOT NULL,
            username TEXT NOT NULL,
            api_version TEXT NOT NULL,
            capabilities TEXT NULL,
            last_synced INTEGER NULL,
            last_full_synced INTEGER NULL,
            is_authenticated INTEGER NULL
          );
        ''');
        raw.execute('''
          INSERT INTO server_config (
            id, name, url, username, api_version, capabilities, last_synced,
            last_full_synced, is_authenticated
          )
          SELECT id, name, url, username, api_version, capabilities,
            last_synced, last_full_synced, NULL
          FROM server_config_legacy;
        ''');
        raw.execute('DROP TABLE server_config_legacy;');
        raw.execute('PRAGMA user_version = 54;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final version = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(version.read<int>('user_version'), 78);
      final state = await migrated.librarySyncDao.getOrCreateState(1);
      expect(state.conditionalIndexesMode, 'reliable');
      expect(state.bulkSearchMode, 'supported');
      expect(state.bulkSearchQuery, '*');
      expect(state.catalogCursor?.toUtc(), checkedAt);
      expect(state.catalogFingerprint, 'artist-1');
      expect(state.auditOffset, 3);
      expect(state.currentGeneration, 1);
      expect(
        (await migrated.serverDao.getActiveServer())?.isAuthenticated,
        isTrue,
      );
      expect(
        (await migrated.libraryDao.getArtistById(
          'artist-1',
        ))?.catalogGeneration,
        1,
      );

      final usageColumns = await migrated
          .customSelect("PRAGMA table_info('network_usage_events');")
          .get();
      expect(
        usageColumns.map((row) => row.read<String>('name')),
        contains('operation'),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v55 to v56 with atomic catalog candidate storage',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v56_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');

      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP TABLE IF EXISTS library_sync_candidate_songs;');
        raw.execute('DROP TABLE IF EXISTS library_sync_candidate_albums;');
        raw.execute('DROP TABLE IF EXISTS library_sync_candidate_artists;');
        raw.execute('DROP TABLE IF EXISTS library_sync_local_mutations;');
        raw.execute(
          'ALTER TABLE library_sync_state DROP COLUMN candidate_generation;',
        );
        raw.execute(
          'ALTER TABLE library_sync_state DROP COLUMN candidate_status;',
        );
        raw.execute(
          'ALTER TABLE library_sync_state DROP COLUMN candidate_started_at;',
        );
        raw.execute(
          'ALTER TABLE library_sync_state '
          'DROP COLUMN candidate_carried_forward_count;',
        );
        raw.execute(
          'ALTER TABLE library_sync_state DROP COLUMN last_apply_duration_ms;',
        );
        raw.execute('PRAGMA user_version = 55;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final version = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(version.read<int>('user_version'), 78);
      final tables = await migrated
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table';")
          .get();
      expect(
        tables.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'library_sync_candidate_artists',
          'library_sync_candidate_albums',
          'library_sync_candidate_songs',
          'library_sync_local_mutations',
        ]),
      );
      final stateColumns = await migrated
          .customSelect("PRAGMA table_info('library_sync_state');")
          .get();
      expect(
        stateColumns.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'candidate_generation',
          'candidate_status',
          'candidate_started_at',
          'candidate_carried_forward_count',
          'last_apply_duration_ms',
        ]),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v56 to v57 with resumable candidate classifications',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v57_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute(
          'DROP INDEX idx_library_sync_candidate_artists_unclassified;',
        );
        raw.execute(
          'DROP INDEX idx_library_sync_candidate_albums_unclassified;',
        );
        raw.execute(
          'DROP INDEX idx_library_sync_candidate_songs_unclassified;',
        );
        raw.execute(
          'ALTER TABLE library_sync_candidate_artists '
          'DROP COLUMN apply_state;',
        );
        raw.execute(
          'ALTER TABLE library_sync_candidate_albums '
          'DROP COLUMN apply_state;',
        );
        raw.execute(
          'ALTER TABLE library_sync_candidate_songs '
          'DROP COLUMN apply_state;',
        );
        raw.execute(
          'ALTER TABLE library_sync_state '
          'DROP COLUMN last_promotion_diagnostics_json;',
        );
        raw.execute('PRAGMA user_version = 56;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final version = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(version.read<int>('user_version'), 78);
      for (final table in <String>[
        'library_sync_candidate_artists',
        'library_sync_candidate_albums',
        'library_sync_candidate_songs',
      ]) {
        final columns = await migrated
            .customSelect("PRAGMA table_info('$table');")
            .get();
        expect(
          columns.map((row) => row.read<String>('name')),
          contains('apply_state'),
        );
      }
      final stateColumns = await migrated
          .customSelect("PRAGMA table_info('library_sync_state');")
          .get();
      expect(
        stateColumns.map((row) => row.read<String>('name')),
        contains('last_promotion_diagnostics_json'),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v57 to v58 with sync work class and unmetered setting',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v58_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seedDatabase = NavisDatabase(NativeDatabase(File(dbPath)));
      await seedDatabase.customSelect('PRAGMA user_version;').getSingle();
      await seedDatabase.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute(
          'ALTER TABLE app_settings '
          'DROP COLUMN background_sync_unmetered_only;',
        );
        raw.execute(
          'ALTER TABLE library_sync_work DROP COLUMN work_class;',
        );
        raw.execute('PRAGMA user_version = 57;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      final version = await migrated
          .customSelect('PRAGMA user_version;')
          .getSingle();
      expect(version.read<int>('user_version'), 78);
      final settingsColumns = await migrated
          .customSelect("PRAGMA table_info('app_settings');")
          .get();
      expect(
        settingsColumns.map((row) => row.read<String>('name')),
        contains('background_sync_unmetered_only'),
      );
      final workColumns = await migrated
          .customSelect("PRAGMA table_info('library_sync_work');")
          .get();
      expect(
        workColumns.map((row) => row.read<String>('name')),
        contains('work_class'),
      );
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v58 provenance while retaining cache and download ownership',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v59_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seed = NavisDatabase(NativeDatabase(File(dbPath)));
      await seed.libraryDao.upsertProvisionalArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(
          id: 'ext-deezer-artist-1',
          name: 'Remote Artist',
        ),
      ]);
      await seed.libraryDao.upsertProvisionalAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'pl-deezer-album-1',
          name: 'Remote Album',
          artistId: const Value('ext-deezer-artist-1'),
        ),
      ]);
      await seed.libraryDao.upsertProvisionalSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'remote-song-1',
          title: 'Remote Song',
          artistId: const Value('ext-deezer-artist-1'),
          albumId: const Value('pl-deezer-album-1'),
        ),
      ]);
      await seed.customStatement(
        'UPDATE artists SET is_provisional = 0; '
        'UPDATE albums SET is_provisional = 0; '
        'UPDATE songs SET is_provisional = 0;',
      );
      await seed.cacheDao.upsertCachedTrack(
        CachedTracksTableCompanion.insert(
          songId: 'remote-song-1',
          filePath: '/tmp/remote-song-1.mp3',
          fileSize: 100,
          format: 'mp3',
          lastAccessedAt: DateTime.utc(2026),
          cacheType: CacheType.permanent,
          downloadStatus: DownloadStatus.complete,
        ),
      );
      await seed.downloadQueueDao.enqueue(
        DownloadQueueTableCompanion.insert(
          songId: const Value('remote-song-1'),
          status: DownloadStatus.queued,
          addedAt: DateTime.utc(2026),
        ),
      );
      await seed.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('ALTER TABLE artists DROP COLUMN is_external;');
        raw.execute('ALTER TABLE albums DROP COLUMN is_external;');
        raw.execute('ALTER TABLE songs DROP COLUMN is_external;');
        raw.execute('PRAGMA user_version = 58;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      expect(migrated.schemaVersion, 78);
      final artist = await migrated.libraryDao.getArtistById(
        'ext-deezer-artist-1',
      );
      final album = await migrated.libraryDao.getAlbumById(
        'pl-deezer-album-1',
      );
      final song = await migrated.libraryDao.getSongById('remote-song-1');
      expect(artist?.isExternal, isTrue);
      expect(artist?.isProvisional, isTrue);
      expect(album?.isExternal, isTrue);
      expect(album?.isProvisional, isTrue);
      expect(song?.isExternal, isTrue);
      expect(song?.isProvisional, isTrue);
      expect(
        await migrated.cacheDao.getCachedTrack('remote-song-1'),
        isNotNull,
      );
      expect(
        await migrated.downloadQueueDao.findBySongId('remote-song-1'),
        isNotNull,
      );
      final integrity = await migrated
          .customSelect('PRAGMA foreign_key_check;')
          .get();
      expect(integrity, isEmpty);
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v59 to v60 with desktop volume defaults',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v60_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seed = NavisDatabase(NativeDatabase(File(dbPath)));
      await seed.customSelect('PRAGMA user_version;').getSingle();
      await seed.customStatement(
        "UPDATE app_settings SET theme_mode = 'oled' WHERE id = 1;",
      );
      await seed.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute(
          'ALTER TABLE app_settings DROP COLUMN desktop_playback_volume;',
        );
        raw.execute(
          'ALTER TABLE app_settings '
          'DROP COLUMN desktop_last_audible_volume;',
        );
        raw.execute('PRAGMA user_version = 59;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      expect(migrated.schemaVersion, 78);
      final settings = await migrated.appSettingsDao.getSettings();
      expect(settings, isNotNull);
      expect(settings!.themeMode, 'oled');
      expect(settings.desktopPlaybackVolume, 1.0);
      expect(settings.desktopLastAudibleVolume, 1.0);
    },
    skip: !sqliteAvailable,
  );

  test(
    'migrates v60 retained server as authenticated',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v61_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seed = NavisDatabase(NativeDatabase(File(dbPath)));
      await seed.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          url: 'https://example.test',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      await seed.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('ALTER TABLE server_config DROP COLUMN is_authenticated;');
        raw.execute('PRAGMA user_version = 60;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      expect(migrated.schemaVersion, 78);
      final retained = await migrated.serverDao.getRetainedServer();
      expect(retained, isNotNull);
      expect(retained!.isAuthenticated, isTrue);
    },
    skip: !sqliteAvailable,
  );

  test('migrates v61 with the starred-absence safety ledger', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v62_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seed = NavisDatabase(NativeDatabase(File(dbPath)));
    await seed.customSelect('PRAGMA user_version;').getSingle();
    await seed.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute('DROP TABLE starred_absence_candidates;');
      raw.execute('PRAGMA user_version = 61;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    expect(migrated.schemaVersion, 78);
    final table = await migrated
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'starred_absence_candidates';",
        )
        .getSingleOrNull();
    expect(table, isNotNull);
  }, skip: !sqliteAvailable);

  test('migrates v62 with a durable automatic sync deadline', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v63_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seed = NavisDatabase(NativeDatabase(File(dbPath)));
    await seed.customSelect('PRAGMA user_version;').getSingle();
    await seed.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute(
        'ALTER TABLE library_sync_state '
        'DROP COLUMN next_automatic_check_at;',
      );
      raw.execute('PRAGMA user_version = 62;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    expect(migrated.schemaVersion, 78);
    final column = await migrated
        .customSelect(
          "SELECT name FROM pragma_table_info('library_sync_state') "
          "WHERE name = 'next_automatic_check_at';",
        )
        .getSingleOrNull();
    expect(column, isNotNull);
  }, skip: !sqliteAvailable);

  test('migrates v63 with the durable sync operation ledger', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'navis_migration_v64_test_',
    );
    final dbPath = p.join(tempDir.path, 'navis.sqlite');
    final seed = NavisDatabase(NativeDatabase(File(dbPath)));
    await seed.customSelect('PRAGMA user_version;').getSingle();
    await seed.close();

    final raw = sqlite3.open(dbPath);
    try {
      raw.execute('DROP TABLE library_sync_operation_ledger;');
      raw.execute('PRAGMA user_version = 63;');
    } finally {
      raw.close();
    }

    final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
    addTearDown(() async {
      await migrated.close();
      await tempDir.delete(recursive: true);
    });

    expect(migrated.schemaVersion, 78);
    final table = await migrated
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'library_sync_operation_ledger';",
        )
        .getSingleOrNull();
    expect(table, isNotNull);
  }, skip: !sqliteAvailable);

  test(
    'migrates v64 with Android background-sync persistence',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'navis_migration_v65_test_',
      );
      final dbPath = p.join(tempDir.path, 'navis.sqlite');
      final seed = NavisDatabase(NativeDatabase(File(dbPath)));
      await seed.customSelect('PRAGMA user_version;').getSingle();
      await seed.close();

      final raw = sqlite3.open(dbPath);
      try {
        raw.execute('DROP TABLE library_sync_execution_lease;');
        for (final column in <String>[
          'android_background_sync_enabled',
          'android_schedule_reconciled_at',
          'android_requested_interval_minutes',
          'android_work_id',
          'android_work_state',
          'android_work_attempt_count',
          'android_worker_started_at',
          'android_worker_completed_at',
          'android_worker_duration_ms',
          'android_worker_result',
          'android_worker_stop_reason',
        ]) {
          raw.execute('ALTER TABLE library_sync_state DROP COLUMN $column;');
        }
        raw.execute('PRAGMA user_version = 64;');
      } finally {
        raw.close();
      }

      final migrated = NavisDatabase(NativeDatabase(File(dbPath)));
      addTearDown(() async {
        await migrated.close();
        await tempDir.delete(recursive: true);
      });

      expect(migrated.schemaVersion, 78);
      final columns = await migrated
          .customSelect("PRAGMA table_info('library_sync_state');")
          .get();
      expect(
        columns.map((row) => row.read<String>('name')).toSet(),
        containsAll(<String>{
          'android_background_sync_enabled',
          'android_schedule_reconciled_at',
          'android_requested_interval_minutes',
          'android_work_id',
          'android_work_state',
          'android_work_attempt_count',
          'android_worker_started_at',
          'android_worker_completed_at',
          'android_worker_duration_ms',
          'android_worker_result',
          'android_worker_stop_reason',
        }),
      );
      final leaseTable = await migrated
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name = 'library_sync_execution_lease';",
          )
          .getSingleOrNull();
      expect(leaseTable, isNotNull);
    },
    skip: !sqliteAvailable,
  );
}
