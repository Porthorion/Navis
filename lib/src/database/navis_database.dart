import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/tables/artist_ref_converter.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/album_info_cache_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/external_lyrics_cache_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/match_flow_songs_table.dart';
import 'package:navis/src/database/tables/match_flows_table.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/network_usage_table.dart';
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
    AlbumInfoCacheTable,
    ExternalLyricsCacheTable,
    PlaylistsTable,
    PlaylistSongsTable,
    CachedTracksTable,
    DownloadQueueTable,
    PlayHistoryTable,
    RecentSearchesTable,
    PlayQueueTable,
    PlayQueueItemsTable,
    MatchFlowsTable,
    MatchFlowSongsTable,
    ScrobbleQueueTable,
    StarSyncQueueTable,
    NetworkUsageTable,
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
    MatchFlowDao,
    ScrobbleDao,
    StarSyncDao,
    NetworkUsageDao,
  ],
)
class NavisDatabase extends _$NavisDatabase {
  NavisDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  static QueryExecutor _openConnection() => driftDatabase(name: 'navis.sqlite');

  @override
  int get schemaVersion => 47;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _ensureGroupListeningColumns();
      await _createIndexes();
      await _ensureAppSettingsDefaults();
    },
    onUpgrade: (m, from, to) async {
      await _runMigrations(m, from, to);
      await _createIndexes();
      await _ensureAppSettingsDefaults();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 5000');
      await _createIndexes();
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
    if (from < 25 && to >= 25) {
      await from24To25(migrator);
    }
    if (from < 26 && to >= 26) {
      await from25To26(migrator);
    }
    if (from < 27 && to >= 27) {
      await from26To27(migrator);
    }
    if (from < 28 && to >= 28) {
      await from27To28(migrator);
    }
    if (from < 29 && to >= 29) {
      await from28To29(migrator);
    }
    if (from < 30 && to >= 30) {
      await from29To30(migrator);
    }
    if (from < 31 && to >= 31) {
      await from30To31(migrator);
    }
    if (from < 32 && to >= 32) {
      await from31To32(migrator);
    }
    if (from < 33 && to >= 33) {
      await from32To33(migrator);
    }
    if (from < 34 && to >= 34) {
      await from33To34(migrator);
    }
    if (from < 35 && to >= 35) {
      await from34To35(migrator);
    }
    if (from < 36 && to >= 36) {
      await from35To36(migrator);
    }
    if (from < 37 && to >= 37) {
      await from36To37(migrator);
    }
    if (from < 38 && to >= 38) {
      await from37To38(migrator);
    }
    if (from < 39 && to >= 39) {
      await from38To39(migrator);
    }
    if (from < 40 && to >= 40) {
      await from39To40(migrator);
    }
    if (from < 41 && to >= 41) {
      await from40To41(migrator);
    }
    if (from < 42 && to >= 42) {
      await from41To42(migrator);
    }
    if (from < 43 && to >= 43) {
      await from42To43(migrator);
    }
    if (from < 44 && to >= 44) {
      await from43To44(migrator);
    }
    if (from < 45 && to >= 45) {
      await from44To45(migrator);
    }
    if (from < 46 && to >= 46) {
      await from45To46(migrator);
    }
    if (from < 47 && to >= 47) {
      await from46To47(migrator);
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

  Future<void> from45To46(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'last_fm_scrobbling_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.lastFmScrobblingEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'last_fm_session_connected')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.lastFmSessionConnected,
      );
    }
    if (!await _columnExists(
      'app_settings',
      'listen_brainz_scrobbling_enabled',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.listenBrainzScrobblingEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'listen_brainz_token_valid')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.listenBrainzTokenValid,
      );
    }
    if (!await _columnExists('app_settings', 'custom_voyage_servers')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.customVoyageServers,
      );
    }
    await _rebuildScrobbleQueueForProviders();
  }

  Future<void> from46To47(Migrator migrator) async {
    if (!await _tableExists('network_usage_events')) {
      await migrator.createTable(networkUsageTable);
    }
  }

  Future<void> _rebuildScrobbleQueueForProviders() async {
    if (!await _tableExists('scrobble_queue')) {
      return;
    }

    await customStatement('DROP TABLE IF EXISTS scrobble_queue_v46;');
    await customStatement('''
CREATE TABLE scrobble_queue_v46 (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  song_id TEXT NOT NULL REFERENCES songs(id) ON DELETE CASCADE,
  provider TEXT NOT NULL DEFAULT 'subsonic',
  submission INTEGER NOT NULL CHECK (submission IN (0, 1)),
  track_title TEXT NULL,
  artist_name TEXT NULL,
  album_name TEXT NULL,
  duration_seconds INTEGER NULL,
  created_at INTEGER NOT NULL,
  next_attempt_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL,
  session_key TEXT NOT NULL,
  last_error TEXT NULL,
  UNIQUE (song_id, provider, submission, session_key)
);
''');
    await customStatement('''
INSERT OR IGNORE INTO scrobble_queue_v46 (
  id,
  song_id,
  provider,
  submission,
  created_at,
  next_attempt_at,
  attempts,
  expires_at,
  session_key,
  last_error
)
SELECT
  id,
  song_id,
  'subsonic',
  submission,
  created_at,
  next_attempt_at,
  attempts,
  expires_at,
  session_key,
  last_error
FROM scrobble_queue;
''');
    await customStatement('DROP TABLE scrobble_queue;');
    await customStatement(
      'ALTER TABLE scrobble_queue_v46 RENAME TO scrobble_queue;',
    );
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
      await migrator.addColumn(appSettingsTable, appSettingsTable.themeMode);
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

  /// Migration v24 → v25:
  /// 1. Recreate `cached_tracks` without the CASCADE FK to `songs` so that
  ///    library sync (which deletes + re-inserts songs) no longer destroys
  ///    download records.
  /// 2. Recreate `download_queue` without FKs and add `retry_count` column.
  Future<void> from24To25(Migrator migrator) async {
    // --- cached_tracks: drop CASCADE FK ---
    await customStatement('PRAGMA foreign_keys = OFF;');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS cached_tracks_new (
        song_id TEXT NOT NULL PRIMARY KEY,
        file_path TEXT NOT NULL,
        file_size INTEGER NOT NULL,
        format TEXT NOT NULL,
        bit_rate INTEGER,
        last_accessed_at INTEGER NOT NULL,
        cache_type TEXT NOT NULL,
        download_status TEXT NOT NULL
      );
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO cached_tracks_new
        (song_id, file_path, file_size, format, bit_rate,
         last_accessed_at, cache_type, download_status)
      SELECT song_id, file_path, file_size, format, bit_rate,
             last_accessed_at, cache_type, download_status
      FROM cached_tracks;
    ''');
    await customStatement('DROP TABLE IF EXISTS cached_tracks;');
    await customStatement(
      'ALTER TABLE cached_tracks_new RENAME TO cached_tracks;',
    );

    // --- download_queue: drop FKs, add retry_count ---
    await customStatement('''
      CREATE TABLE IF NOT EXISTS download_queue_new (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        song_id TEXT,
        album_id TEXT,
        playlist_id TEXT,
        quality TEXT,
        format TEXT,
        status TEXT NOT NULL,
        progress REAL NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        retry_count INTEGER NOT NULL DEFAULT 0
      );
    ''');
    await customStatement('''
      INSERT OR IGNORE INTO download_queue_new
        (id, song_id, album_id, playlist_id, quality, format,
         status, progress, added_at, priority, retry_count)
      SELECT id, song_id, album_id, playlist_id, quality, format,
             status, progress, added_at, priority, 0
      FROM download_queue;
    ''');
    await customStatement('DROP TABLE IF EXISTS download_queue;');
    await customStatement(
      'ALTER TABLE download_queue_new RENAME TO download_queue;',
    );

    await customStatement('PRAGMA foreign_keys = ON;');
  }

  Future<void> from25To26(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'app_locale')) {
      await migrator.addColumn(appSettingsTable, appSettingsTable.appLocale);
    }
  }

  Future<void> from26To27(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'album_grid_density')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.albumGridDensity,
      );
    }
    if (!await _columnExists('app_settings', 'cover_art_border_radius')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.coverArtBorderRadius,
      );
    }
    if (!await _columnExists('app_settings', 'now_playing_art_border_radius')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.nowPlayingArtBorderRadius,
      );
    }
    if (!await _columnExists('app_settings', 'artist_view_mode')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.artistViewMode,
      );
    }
    if (!await _columnExists('app_settings', 'home_section_order')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.homeSectionOrder,
      );
    }
    if (!await _columnExists('app_settings', 'home_sections_hidden')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.homeSectionsHidden,
      );
    }
  }

  Future<void> from27To28(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'cover_art_shape')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.coverArtShape,
      );
    }
    if (!await _columnExists('app_settings', 'now_playing_art_shape')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.nowPlayingArtShape,
      );
    }
    if (!await _columnExists('app_settings', 'artist_card_shape')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.artistCardShape,
      );
    }
  }

  Future<void> from28To29(Migrator migrator) async {
    if (!await _columnExists('songs', 'user_rating')) {
      await migrator.addColumn(songsTable, songsTable.userRating);
    }
    if (!await _columnExists('albums', 'user_rating')) {
      await migrator.addColumn(albumsTable, albumsTable.userRating);
    }
    if (!await _tableExists('album_info_cache')) {
      await migrator.createTable(albumInfoCacheTable);
    }
    if (!await _tableExists('external_lyrics_cache')) {
      await migrator.createTable(externalLyricsCacheTable);
    }
    if (!await _columnExists('app_settings', 'use_lrclib')) {
      await migrator.addColumn(appSettingsTable, appSettingsTable.useLrclib);
    }
  }

  Future<void> from29To30(Migrator migrator) async {
    if (!await _columnExists('songs', 'sample_rate')) {
      await migrator.addColumn(songsTable, songsTable.sampleRate);
    }
  }

  Future<void> from30To31(Migrator migrator) async {
    // Reserved migration slot from prior desktop UI v1 rollout.
    // Kept as no-op so existing user_version chains remain intact.
  }

  Future<void> from31To32(Migrator migrator) async {
    // Desktop UI v1 was removed from runtime behavior.
    // No table rewrite is required here; legacy columns are tolerated.
  }

  Future<void> from32To33(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'home_density')) {
      await migrator.addColumn(appSettingsTable, appSettingsTable.homeDensity);
    }
  }

  Future<void> from33To34(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'legacy_instant_mix_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.legacyInstantMixEnabled,
      );
    }
  }

  Future<void> from34To35(Migrator migrator) async {
    if (!await _columnExists(
      'app_settings',
      'desktop_focus_player_mode_enabled',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.desktopFocusPlayerModeEnabled,
      );
    }
  }

  Future<void> from35To36(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'desktop_navbar_style')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.desktopNavbarStyle,
      );
    }
    if (!await _columnExists('app_settings', 'desktop_navbar_autohide')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.desktopNavbarAutohide,
      );
    }
  }

  Future<void> from36To37(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'album_queue_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.albumQueueEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'liked_queue_enabled')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.likedQueueEnabled,
      );
    }
  }

  Future<void> from37To38(Migrator migrator) async {
    if (!await _columnExists('albums', 'artists')) {
      await migrator.addColumn(albumsTable, albumsTable.artists);
    }
  }

  Future<void> from38To39(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'last_full_sync_app_build')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.lastFullSyncAppBuild,
      );
    }
  }

  Future<void> from39To40(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'last_fm_api_key')) {
      await migrator.addColumn(appSettingsTable, appSettingsTable.lastFmApiKey);
    }
  }

  Future<void> from40To41(Migrator _) async {
    await _ensureGroupListeningColumns();
  }

  Future<void> from41To42(Migrator migrator) async {
    await _ensureMatchFlowStorage(migrator);
  }

  Future<void> from42To43(Migrator migrator) async {
    if (!await _columnExists('songs', 'server_deleted_at')) {
      await migrator.addColumn(songsTable, songsTable.serverDeletedAt);
    }
  }

  Future<void> from43To44(Migrator migrator) async {
    if (!await _columnExists(
      'app_settings',
      'custom_download_folder_enabled',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.customDownloadFolderEnabled,
      );
    }
    if (!await _columnExists('app_settings', 'custom_download_folder_path')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.customDownloadFolderPath,
      );
    }
  }

  Future<void> from44To45(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'cached_playback_first')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.cachedPlaybackFirst,
      );
    }
  }

  Future<void> _ensureGroupListeningColumns() async {
    if (!await _columnExists('app_settings', 'group_listening_enabled')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN group_listening_enabled INTEGER NOT NULL DEFAULT 0;
      ''');
    }
    if (!await _columnExists('app_settings', 'voyage_server_url')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN voyage_server_url TEXT;
      ''');
    }
    if (!await _columnExists('app_settings', 'voyage_display_name')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN voyage_display_name TEXT;
      ''');
    }
    if (!await _columnExists('app_settings', 'voyage_device_label')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN voyage_device_label TEXT;
      ''');
    }
    if (!await _columnExists('app_settings', 'voyage_auto_follow_host')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN voyage_auto_follow_host INTEGER NOT NULL DEFAULT 1;
      ''');
    }
  }

  Future<void> _ensureMatchFlowStorage([Migrator? migrator]) async {
    if (!await _tableExists('match_flows')) {
      await (migrator?.createTable(matchFlowsTable) ??
          customStatement('''
            CREATE TABLE match_flows (
              id TEXT NOT NULL PRIMARY KEY,
              name TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1,
              created_at INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            );
          '''));
    }
    if (!await _tableExists('match_flow_songs')) {
      await (migrator?.createTable(matchFlowSongsTable) ??
          customStatement('''
            CREATE TABLE match_flow_songs (
              flow_id TEXT NOT NULL,
              song_id TEXT NOT NULL,
              sort_order INTEGER NOT NULL,
              added_at INTEGER NOT NULL,
              PRIMARY KEY (flow_id, song_id),
              FOREIGN KEY (flow_id)
                REFERENCES match_flows(id)
                ON DELETE CASCADE
            );
          '''));
    }
    if (!await _columnExists('app_settings', 'match_flow_enabled')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN match_flow_enabled INTEGER NOT NULL DEFAULT 0;
      ''');
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
        cachedPlaybackFirst: const Value(false),
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
        wifiOnlyDownloads: const Value(true),
        autoDownloadStarredOnWifi: const Value(false),
        customDownloadFolderEnabled: const Value(false),
        customDownloadFolderPath: const Value(null),
        useLrclib: const Value(true),
        themeMode: const Value('dark'),
        colorSchemeSeed: const Value(null),
        matchFlowEnabled: const Value(false),
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
      'CREATE INDEX IF NOT EXISTS idx_songs_server_deleted_at ON songs(server_deleted_at, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_playlist_songs_order ON playlist_songs(playlist_id, sort_order);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_play_queue_items_order ON play_queue_items(queue_id, sort_order);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_match_flow_songs_order ON match_flow_songs(flow_id, sort_order);',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_match_flow_unique_master ON match_flow_songs(song_id) WHERE sort_order = 0;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_scrobble_queue_due ON scrobble_queue(next_attempt_at, expires_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_network_usage_occurred_at ON network_usage_events(occurred_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_network_usage_category_network ON network_usage_events(category, network_type);',
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
