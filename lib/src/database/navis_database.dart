import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/play_queue_items_table.dart';
import 'package:navis/src/database/tables/play_queue_table.dart';
import 'package:navis/src/database/tables/playlist_songs_table.dart';
import 'package:navis/src/database/tables/playlists_table.dart';
import 'package:navis/src/database/tables/recent_searches_table.dart';
import 'package:navis/src/database/tables/scrobble_queue_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/server_config_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'navis_database.g.dart';

@DriftDatabase(
  tables: [
    ServerConfigTable,
    AppSettingsTable,
    ArtistsTable,
    AlbumsTable,
    SongsTable,
    GenresTable,
    PlaylistsTable,
    PlaylistSongsTable,
    CachedTracksTable,
    DownloadQueueTable,
    PlayHistoryTable,
    RecentSearchesTable,
    PlayQueueTable,
    PlayQueueItemsTable,
    ScrobbleQueueTable,
  ],
  daos: [
    AppSettingsDao,
    ServerDao,
    LibraryDao,
    PlaylistDao,
    CacheDao,
    DownloadQueueDao,
    HistoryDao,
    PlayQueueDao,
    ScrobbleDao,
  ],
)
class NavisDatabase extends _$NavisDatabase {
  NavisDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  static QueryExecutor _openConnection() => driftDatabase(name: 'navis.sqlite');

  @override
  int get schemaVersion => 13;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await _createIndexes();
      await _ensureAppSettingsDefaults();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await _runMigrations(m, from, to);
      await _createIndexes();
      await _ensureAppSettingsDefaults();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await _createIndexes();
      await _ensureAppSettingsDefaults();
    },
  );

  Future<void> _runMigrations(Migrator migrator, int from, int to) async {
    if (from < 2 && to >= 2) {
      await from1To2(migrator);
    }
    if (from < 3 && to >= 3) {
      await from2To3(migrator);
    }
    if (from < 4 && to >= 4) {
      await from3To4(migrator);
    }
    if (from < 5 && to >= 5) {
      await from4To5(migrator);
    }
    if (from < 6 && to >= 6) {
      await from5To6(migrator);
    }
    if (from < 7 && to >= 7) {
      await from6To7(migrator);
    }
    if (from < 8 && to >= 8) {
      await from7To8(migrator);
    }
    if (from < 9 && to >= 9) {
      await from8To9(migrator);
    }
    if (from < 10 && to >= 10) {
      await from9To10(migrator);
    }
    if (from < 11 && to >= 11) {
      await from10To11(migrator);
    }
    if (from < 12 && to >= 12) {
      await from11To12(migrator);
    }
    if (from < 13 && to >= 13) {
      await from12To13(migrator);
    }
  }

  Future<void> from1To2(Migrator migrator) async {
    if (await _columnExists('server_config', 'last_full_synced')) {
      return;
    }
    await migrator.addColumn(
      serverConfigTable,
      serverConfigTable.lastFullSynced,
    );
  }

  Future<void> from2To3(Migrator migrator) async {
    if (!await _columnExists('albums', 'songs_hydrated')) {
      await migrator.addColumn(albumsTable, albumsTable.songsHydrated);
    }
    await backfillAlbumHydrationState();
  }

  Future<void> from3To4(Migrator migrator) async {
    if (await _tableExists('app_settings')) {
      return;
    }
    await migrator.createTable(appSettingsTable);
  }

  Future<void> from4To5(Migrator migrator) async {
    if (await _tableExists('scrobble_queue')) {
      return;
    }
    await migrator.createTable(scrobbleQueueTable);
  }

  Future<void> from5To6(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'gapless_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.gaplessEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'skip_silence_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.skipSilenceEnabled,
      );
    }
  }

  Future<void> from6To7(Migrator migrator) async {
    if (await _columnExists('songs', 'created_at')) {
      return;
    }
    await migrator.addColumn(songsTable, songsTable.createdAt);
  }

  Future<void> from7To8(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'show_radio_page')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.showRadioPage,
      );
    }
    if (!await _columnExists('app_settings', 'equalizer_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.equalizerEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'equalizer_band_gains')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.equalizerBandGains,
      );
    }
    if (!await _columnExists('app_settings', 'loudness_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.loudnessEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'loudness_target_gain_db')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.loudnessTargetGainDb,
      );
    }
  }

  Future<void> from8To9(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'rolling_cache_budget_mb')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.rollingCacheBudgetMb,
      );
    }
  }

  Future<void> from9To10(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'wifi_only_downloads')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.wifiOnlyDownloads,
      );
    }
  }

  Future<void> from10To11(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'theme_mode')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.themeMode,
      );
    }
    if (!await _columnExists('app_settings', 'color_scheme_seed')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.colorSchemeSeed,
      );
    }
  }

  Future<void> from11To12(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'custom_color_presets')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.customColorPresets,
      );
    }
  }

  Future<void> from12To13(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'crossfade_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.crossfadeEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'crossfade_duration_seconds')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.crossfadeDurationSeconds,
      );
    }
    if (!await _columnExists('app_settings', 'crossfade_type')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.crossfadeType,
      );
    }
  }

  Future<void> _ensureAppSettingsDefaults() {
    return into(appSettingsTable).insert(
      AppSettingsTableCompanion.insert(
        id: Value(AppSettingsDao.primarySettingsId),
        wifiMaxBitRate: const Value(null),
        wifiFormat: const Value(null),
        cellularMaxBitRate: const Value(AppSettingsDao.defaultCellularBitRate),
        cellularFormat: const Value(AppSettingsDao.defaultCellularFormat),
        scrobbleEnabled: const Value(true),
        gaplessEnabled: const Value(true),
        skipSilenceEnabled: const Value(false),
        showRadioPage: const Value(true),
        equalizerEnabled: const Value(false),
        equalizerBandGains: const Value(null),
        loudnessEnabled: const Value(false),
        loudnessTargetGainDb: const Value(0),
        rollingCacheBudgetMb: const Value(
          AppSettingsDao.defaultRollingCacheBudgetMb,
        ),
        wifiOnlyDownloads: const Value(false),
        themeMode: const Value('dark'),
        colorSchemeSeed: const Value(null),
        updatedAt: DateTime.now(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> backfillAlbumHydrationState() async {
    await customStatement('''
      UPDATE albums
      SET songs_hydrated = CASE
        WHEN EXISTS (
          SELECT 1
          FROM songs
          WHERE songs.album_id = albums.id
          LIMIT 1
        ) THEN 1
        ELSE 0
      END;
    ''');
  }

  Future<void> _createIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_artists_name ON artists(name);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_artist_year ON albums(artist_id, year);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_year_name ON albums(year DESC, name ASC, id ASC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_artist_name_sort ON albums(artist_name ASC, name ASC, id ASC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_songs_hydrated ON albums(songs_hydrated, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_album_track ON songs(album_id, track);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_created_at ON songs(created_at DESC, id ASC);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_playlist_songs_order ON playlist_songs(playlist_id, sort_order);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_play_queue_items_order ON play_queue_items(queue_id, sort_order);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scrobble_queue_due ON scrobble_queue(next_attempt_at, expires_at);',
    );
  }

  Future<bool> _tableExists(String tableName) async {
    final rows = await customSelect(
      'SELECT 1 AS value FROM sqlite_master '
      "WHERE type = 'table' AND name = ? LIMIT 1;",
      variables: <Variable<Object>>[Variable<String>(tableName)],
    ).get();
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(String tableName, String columnName) async {
    final rows = await customSelect("PRAGMA table_info('$tableName');").get();
    for (final row in rows) {
      if (row.read<String>('name') == columnName) {
        return true;
      }
    }
    return false;
  }
}
