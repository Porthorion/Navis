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
import 'package:navis/src/database/daos/star_sync_dao.dart';
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
import 'package:navis/src/database/tables/star_sync_queue_table.dart';

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
    StarSyncQueueTable,
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
    StarSyncDao,
  ],
)
class NavisDatabase extends _$NavisDatabase {
  NavisDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  static QueryExecutor _openConnection() => driftDatabase(name: 'navis.sqlite');

  @override
  int get schemaVersion => 24;

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
    if (from < 14 && to >= 14) {
      await from13To14(migrator);
    }
    if (from < 15 && to >= 15) {
      await from14To15(migrator);
    }
    if (from < 16 && to >= 16) {
      await from15To16(migrator);
    }
    if (from < 17 && to >= 17) {
      await from16To17(migrator);
    }
    if (from < 18 && to >= 18) {
      await from17To18(migrator);
    }
    if (from < 19 && to >= 19) {
      await from18To19(migrator);
    }
    if (from < 20 && to >= 20) {
      await from19To20(migrator);
    }
    if (from < 21 && to >= 21) {
      await from20To21(migrator);
    }
    if (from < 22 && to >= 22) {
      await from21To22(migrator);
    }
    if (from < 23 && to >= 23) {
      await from22To23(migrator);
    }
    if (from < 24 && to >= 24) {
      await from23To24(migrator);
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

  Future<void> from13To14(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'cover_art_cache_max_objects')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.coverArtCacheMaxObjects,
      );
    }
    if (!await _columnExists('app_settings', 'art_tinted_now_playing')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.artTintedNowPlaying,
      );
    }
  }

  Future<void> from14To15(Migrator migrator) async {
    // Change the default for art_tinted_now_playing from false to true.
    // Flip existing rows that still have the old default.
    await customStatement(
      'UPDATE app_settings SET art_tinted_now_playing = 1 '
      'WHERE art_tinted_now_playing = 0;',
    );
  }

  Future<void> from18To19(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'update_check_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.updateCheckEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'update_channel')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.updateChannel,
      );
    }
  }

  Future<void> from19To20(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'audio_muse_server_url')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.audioMuseServerUrl,
      );
    }
    if (!await _columnExists('app_settings', 'audio_muse_api_key')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.audioMuseApiKey,
      );
    }
    if (!await _columnExists('app_settings', 'audio_muse_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.audioMuseEnabled,
      );
    }
  }

  Future<void> from20To21(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'sync_interval_minutes')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.syncIntervalMinutes,
      );
    }
  }

  Future<void> from21To22(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'dynamic_album_color_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.dynamicAlbumColorEnabled,
      );
    }
  }

  Future<void> from22To23(Migrator migrator) async {
    // 16.1: Star sync queue table.
    if (!await _tableExists('star_sync_queue')) {
      await migrator.createTable(starSyncQueueTable);
    }

    // 14.4: ReplayGain columns on songs.
    if (!await _columnExists('songs', 'replay_gain_track_gain')) {
      await migrator.addColumn(songsTable, songsTable.replayGainTrackGain);
    }
    if (!await _columnExists('songs', 'replay_gain_album_gain')) {
      await migrator.addColumn(songsTable, songsTable.replayGainAlbumGain);
    }
    if (!await _columnExists('songs', 'replay_gain_track_peak')) {
      await migrator.addColumn(songsTable, songsTable.replayGainTrackPeak);
    }
    if (!await _columnExists('songs', 'replay_gain_album_peak')) {
      await migrator.addColumn(songsTable, songsTable.replayGainAlbumPeak);
    }

    // 14.4: ReplayGain mode and pre-amp on app_settings.
    if (!await _columnExists('app_settings', 'replay_gain_mode')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.replayGainMode,
      );
    }
    if (!await _columnExists('app_settings', 'replay_gain_preamp')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.replayGainPreamp,
      );
    }

    // 14.5: Playback speed on app_settings.
    if (!await _columnExists('app_settings', 'playback_speed')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.playbackSpeed,
      );
    }
  }

  Future<void> from23To24(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'show_liked_page')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.showLikedPage,
      );
    }
    if (!await _columnExists('app_settings', 'auto_download_starred_on_wifi')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.autoDownloadStarredOnWifi,
      );
    }
  }

  Future<void> from17To18(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'show_playlists_page')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.showPlaylistsPage,
      );
    }
    if (!await _columnExists('app_settings', 'show_artists_page')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.showArtistsPage,
      );
    }
  }

  Future<void> from16To17(Migrator migrator) async {
    if (!await _columnExists('albums', 'server_created_at')) {
      await migrator.addColumn(albumsTable, albumsTable.serverCreatedAt);
    }
  }

  Future<void> from15To16(Migrator migrator) async {
    if (!await _columnExists('albums', 'synced_at')) {
      await migrator.addColumn(albumsTable, albumsTable.syncedAt);
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
        showPlaylistsPage: const Value(true),
        showArtistsPage: const Value(true),
        showLikedPage: const Value(true),
        equalizerEnabled: const Value(false),
        equalizerBandGains: const Value(null),
        loudnessEnabled: const Value(false),
        loudnessTargetGainDb: const Value(0),
        rollingCacheBudgetMb: const Value(
          AppSettingsDao.defaultRollingCacheBudgetMb,
        ),
        wifiOnlyDownloads: const Value(false),
        autoDownloadStarredOnWifi: const Value(false),
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
