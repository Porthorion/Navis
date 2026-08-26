import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/tables/artist_ref_converter.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/cache_system_state_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/listenbrainz_feedback_dao.dart';
import 'package:navis/src/database/daos/library_sync_dao.dart';
import 'package:navis/src/database/daos/library_sync_candidate_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/daos/network_usage_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/daos/scrobble_dao.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/daos/song_identity_dao.dart';
import 'package:navis/src/database/daos/star_sync_dao.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/app_settings_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/album_info_cache_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/cache_system_state_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/external_lyrics_cache_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/listenbrainz_feedback_queue_table.dart';
import 'package:navis/src/database/tables/listenbrainz_weekly_cache_table.dart';
import 'package:navis/src/database/tables/library_sync_state_table.dart';
import 'package:navis/src/database/tables/library_sync_work_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_albums_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_artists_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_songs_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';
import 'package:navis/src/database/tables/library_sync_operation_ledger_table.dart';
import 'package:navis/src/database/tables/library_sync_execution_lease_table.dart';
import 'package:navis/src/database/tables/library_sync_provider_profile_table.dart';
import 'package:navis/src/database/tables/library_sync_repair_session_table.dart';
import 'package:navis/src/database/tables/library_sync_run_attempt_table.dart';
import 'package:navis/src/database/tables/library_sync_run_outcome_table.dart';
import 'package:navis/src/database/tables/library_sync_run_request_table.dart';
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
import 'package:navis/src/database/tables/song_identity_aliases_table.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';
import 'package:navis/src/database/tables/starred_absence_candidates_table.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

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
    CacheSystemStateTable,
    DownloadQueueTable,
    PlayHistoryTable,
    RecentSearchesTable,
    PlayQueueTable,
    PlayQueueItemsTable,
    MatchFlowsTable,
    MatchFlowSongsTable,
    ScrobbleQueueTable,
    StarSyncQueueTable,
    ListenBrainzFeedbackQueueTable,
    ListenBrainzWeeklyCacheTable,
    NetworkUsageTable,
    SongIdentityAliasesTable,
    LibrarySyncStateTable,
    LibrarySyncWorkTable,
    LibrarySyncCandidateArtistsTable,
    LibrarySyncCandidateAlbumsTable,
    LibrarySyncCandidateSongsTable,
    LibrarySyncLocalMutationsTable,
    StarredAbsenceCandidatesTable,
    LibrarySyncOperationLedgerTable,
    LibrarySyncExecutionLeaseTable,
    LibrarySyncRunRequestTable,
    LibrarySyncRunAttemptTable,
    LibrarySyncRunOutcomeTable,
    LibrarySyncProviderProfileTable,
    LibrarySyncRepairSessionTable,
  ],
  daos: [
    AppSettingsDao,
    ServerDao,
    LibraryDao,
    PlaylistDao,
    CacheDao,
    CacheSystemStateDao,
    DownloadQueueDao,
    HistoryDao,
    PlayQueueDao,
    MatchFlowDao,
    ScrobbleDao,
    StarSyncDao,
    ListenBrainzFeedbackDao,
    NetworkUsageDao,
    SongIdentityDao,
    LibrarySyncDao,
    LibrarySyncCandidateDao,
  ],
)
class NavisDatabase extends _$NavisDatabase {
  NavisDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  NavisDatabase.atPath(String databasePath)
    : this(_openFileConnection(File(databasePath)));

  static QueryExecutor _openConnection() => LazyDatabase(() async {
    final directory = await getApplicationDocumentsDirectory();
    return _openFileConnection(
      File(p.join(directory.path, 'navis.sqlite.sqlite')),
    );
  });

  static QueryExecutor _openFileConnection(File file) {
    return NativeDatabase.createInBackground(
      file,
      setup: _configureNativeDatabase,
      // WAL lets ordinary reads continue while sync writes its hidden
      // candidate catalog. One reader keeps device overhead low.
      readPool: 1,
    );
  }

  @override
  int get schemaVersion => 73;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _ensureGroupListeningColumns();
      await _createIndexes();
      await _ensureAppSettingsDefaults();
      await cacheSystemStateDao.markVersion(3);
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
    if (from < 48 && to >= 48) {
      await from47To48(migrator);
    }
    if (from < 49 && to >= 49) {
      await from48To49(migrator);
    }
    if (from < 50 && to >= 50) {
      await from49To50(migrator);
    }
    if (from < 51 && to >= 51) {
      await from50To51(migrator);
    }
    if (from < 52 && to >= 52) {
      await from51To52(migrator);
    }
    if (from < 53 && to >= 53) {
      await from52To53(migrator);
    }
    if (from < 54 && to >= 54) {
      await from53To54(migrator);
    }
    if (from < 55 && to >= 55) {
      await from54To55(migrator);
    }
    if (from < 56 && to >= 56) {
      await from55To56(migrator);
    }
    if (from < 57 && to >= 57) {
      await from56To57(migrator);
    }
    if (from < 58 && to >= 58) {
      await from57To58(migrator);
    }
    if (from < 59 && to >= 59) {
      await from58To59(migrator);
    }
    if (from < 60 && to >= 60) {
      await from59To60(migrator);
    }
    if (from < 61 && to >= 61) {
      await from60To61(migrator);
    }
    if (from < 62 && to >= 62) {
      await from61To62(migrator);
    }
    if (from < 63 && to >= 63) {
      await from62To63(migrator);
    }
    if (from < 64 && to >= 64) {
      await from63To64(migrator);
    }
    if (from < 65 && to >= 65) {
      await from64To65(migrator);
    }
    if (from < 66 && to >= 66) {
      await from65To66(migrator);
    }
    if (from < 67 && to >= 67) {
      await from66To67(migrator);
    }
    if (from < 68 && to >= 68) {
      await from67To68(migrator);
    }
    if (from < 69 && to >= 69) {
      await from68To69(migrator);
    }
    if (from < 70 && to >= 70) {
      await from69To70(migrator);
    }
    if (from < 71 && to >= 71) {
      await from70To71(migrator);
    }
    if (from < 72 && to >= 72) {
      await from71To72(migrator);
    }
    if (from < 73 && to >= 73) {
      await from72To73(migrator);
    }
  }

  /// Repairs legacy remote-prefixed rows that were written before source
  /// provenance was persisted reliably. Without this pass they look local to
  /// Home and album-list queries despite being remote-only releases.
  Future<void> from72To73(Migrator migrator) async {
    for (final table in <String>['artists', 'albums', 'songs']) {
      await customStatement('''
        UPDATE $table
        SET is_external = 1,
            is_provisional = 1
        WHERE is_external = 0
          AND (
            lower(id) LIKE 'ext-%'
            OR lower(id) LIKE 'remote-%'
            OR lower(id) LIKE 'pl-deezer-%'
          );
      ''');
    }
  }

  /// Persists server-authoritative Recently Added order through a hidden
  /// full-catalog candidate before its atomic promotion.
  Future<void> from71To72(Migrator migrator) async {
    if (!await _columnExists(
      'library_sync_candidate_albums',
      'recently_added_rank',
    )) {
      await migrator.addColumn(
        librarySyncCandidateAlbumsTable,
        librarySyncCandidateAlbumsTable.recentlyAddedRank,
      );
    }
  }

  /// Adds the typed sync-lifecycle store alongside the legacy work rows.
  ///
  /// The current executor continues to mirror legacy work during the first
  /// compatibility release, so an app rollback never needs to reverse a
  /// schema migration or reconstruct a catalog from diagnostics.
  Future<void> from70To71(Migrator migrator) async {
    if (!await _tableExists('library_sync_run_request')) {
      await migrator.createTable(librarySyncRunRequestTable);
    }
    if (!await _tableExists('library_sync_run_attempt')) {
      await migrator.createTable(librarySyncRunAttemptTable);
    }
    if (!await _tableExists('library_sync_run_outcome')) {
      await migrator.createTable(librarySyncRunOutcomeTable);
    }
    if (!await _tableExists('library_sync_provider_profile')) {
      await migrator.createTable(librarySyncProviderProfileTable);
    }
    if (!await _tableExists('library_sync_repair_session')) {
      await migrator.createTable(librarySyncRepairSessionTable);
    }
  }

  Future<void> from69To70(Migrator migrator) async {
    if (!await _columnExists('albums', 'recently_added_rank')) {
      await migrator.addColumn(albumsTable, albumsTable.recentlyAddedRank);
    }
  }

  Future<void> from68To69(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'onboarding_version')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.onboardingVersion,
      );
    }
    // This release intentionally makes album and liked-page queue expansion
    // the default for every local profile, not only new installations.
    await customStatement('''
      UPDATE app_settings
      SET album_queue_enabled = 1, liked_queue_enabled = 1;
    ''');
  }

  Future<void> from67To68(Migrator migrator) async {
    if (!await _columnExists(
      'app_settings',
      'custom_download_folder_storage_kind',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.customDownloadFolderStorageKind,
      );
    }
  }

  Future<void> from66To67(Migrator migrator) async {
    if (!await _columnExists('cached_tracks', 'storage_kind')) {
      await migrator.addColumn(
        cachedTracksTable,
        cachedTracksTable.storageKind,
      );
    }
  }

  /// Adds the durable marker without marking an upgraded profile as current.
  /// A missing row is therefore the explicit legacy-cache upgrade signal.
  Future<void> from65To66(Migrator migrator) async {
    if (!await _tableExists('cache_system_state')) {
      await migrator.createTable(cacheSystemStateTable);
    }
  }

  Future<void> from64To65(Migrator migrator) async {
    if (!await _tableExists('library_sync_execution_lease')) {
      await migrator.createTable(librarySyncExecutionLeaseTable);
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_background_sync_enabled',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidBackgroundSyncEnabled,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_schedule_reconciled_at',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidScheduleReconciledAt,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_requested_interval_minutes',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidRequestedIntervalMinutes,
      );
    }
    if (!await _columnExists('library_sync_state', 'android_work_id')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkId,
      );
    }
    if (!await _columnExists('library_sync_state', 'android_work_state')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkState,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_work_attempt_count',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkAttemptCount,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_worker_started_at',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkerStartedAt,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_worker_completed_at',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkerCompletedAt,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_worker_duration_ms',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkerDurationMs,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_worker_result',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkerResult,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'android_worker_stop_reason',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.androidWorkerStopReason,
      );
    }
  }

  Future<void> from63To64(Migrator migrator) async {
    if (!await _tableExists('library_sync_operation_ledger')) {
      await migrator.createTable(librarySyncOperationLedgerTable);
    }
  }

  Future<void> from62To63(Migrator migrator) async {
    if (!await _columnExists('library_sync_state', 'next_automatic_check_at')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.nextAutomaticCheckAt,
      );
    }
  }

  Future<void> from61To62(Migrator migrator) async {
    if (!await _tableExists('starred_absence_candidates')) {
      await migrator.createTable(starredAbsenceCandidatesTable);
    }
  }

  Future<void> from60To61(Migrator migrator) async {
    if (!await _columnExists('server_config', 'is_authenticated')) {
      await migrator.addColumn(
        serverConfigTable,
        serverConfigTable.isAuthenticated,
      );
    }
    await customStatement(
      'UPDATE server_config SET is_authenticated = 1 '
      'WHERE is_authenticated IS NULL',
    );
  }

  Future<void> from59To60(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'desktop_playback_volume')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.desktopPlaybackVolume,
      );
    }
    if (!await _columnExists(
      'app_settings',
      'desktop_last_audible_volume',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.desktopLastAudibleVolume,
      );
    }
  }

  Future<void> from58To59(Migrator migrator) async {
    if (!await _columnExists('artists', 'is_external')) {
      await migrator.addColumn(artistsTable, artistsTable.isExternal);
    }
    if (!await _columnExists('albums', 'is_external')) {
      await migrator.addColumn(albumsTable, albumsTable.isExternal);
    }
    if (!await _columnExists('songs', 'is_external')) {
      await migrator.addColumn(songsTable, songsTable.isExternal);
    }

    for (final table in <String>['artists', 'albums', 'songs']) {
      await customStatement('''
        UPDATE $table
        SET is_external = 1,
            is_provisional = 1
        WHERE lower(id) LIKE 'ext-%'
           OR lower(id) LIKE 'remote-%'
           OR lower(id) LIKE 'pl-deezer-%';
      ''');
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

  Future<void> from47To48(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'listen_brainz_user_name')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.listenBrainzUserName,
      );
    }
  }

  Future<void> from48To49(Migrator migrator) async {
    if (!await _columnExists('songs', 'recording_mbid')) {
      await migrator.addColumn(songsTable, songsTable.recordingMbid);
    }
    if (!await _tableExists('listenbrainz_feedback_queue')) {
      await migrator.createTable(listenBrainzFeedbackQueueTable);
    }
  }

  Future<void> from49To50(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'library_page_order')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.libraryPageOrder,
      );
    }
  }

  Future<void> from50To51(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'show_albums_page')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.showAlbumsPage,
      );
    }
  }

  Future<void> from51To52(Migrator migrator) async {
    if (!await _tableExists('listenbrainz_weekly_cache')) {
      await migrator.createTable(listenBrainzWeeklyCacheTable);
    }
  }

  Future<void> from52To53(Migrator _) async {
    await _clearRetiredGroupListeningSettings();
  }

  Future<void> from53To54(Migrator migrator) async {
    if (!await _columnExists('artists', 'is_provisional')) {
      await migrator.addColumn(artistsTable, artistsTable.isProvisional);
    }
    if (!await _columnExists('albums', 'is_provisional')) {
      await migrator.addColumn(albumsTable, albumsTable.isProvisional);
    }
    if (!await _columnExists('songs', 'is_provisional')) {
      await migrator.addColumn(songsTable, songsTable.isProvisional);
    }
    if (!await _tableExists('song_identity_aliases')) {
      await migrator.createTable(songIdentityAliasesTable);
    }
  }

  Future<void> from54To55(Migrator migrator) async {
    if (!await _columnExists('artists', 'catalog_generation')) {
      await migrator.addColumn(artistsTable, artistsTable.catalogGeneration);
    }
    if (!await _columnExists('albums', 'catalog_generation')) {
      await migrator.addColumn(albumsTable, albumsTable.catalogGeneration);
    }
    if (!await _columnExists('songs', 'catalog_generation')) {
      await migrator.addColumn(songsTable, songsTable.catalogGeneration);
    }
    if (!await _columnExists('network_usage_events', 'operation')) {
      await migrator.addColumn(networkUsageTable, networkUsageTable.operation);
    }
    if (!await _tableExists('library_sync_state')) {
      await migrator.createTable(librarySyncStateTable);
    }
    if (!await _tableExists('library_sync_work')) {
      await migrator.createTable(librarySyncWorkTable);
    }
    await _importLegacyLibrarySyncState();
    await customStatement(
      'UPDATE artists SET catalog_generation = 1 '
      'WHERE is_provisional = 0 AND '
      '(catalog_generation IS NULL OR catalog_generation = 0)',
    );
    await customStatement(
      'UPDATE albums SET catalog_generation = 1 '
      'WHERE is_provisional = 0 AND '
      '(catalog_generation IS NULL OR catalog_generation = 0)',
    );
    await customStatement(
      'UPDATE songs SET catalog_generation = 1 '
      'WHERE is_provisional = 0 AND '
      '(catalog_generation IS NULL OR catalog_generation = 0)',
    );
    await customStatement(
      'UPDATE library_sync_state SET current_generation = 1 '
      'WHERE last_catalog_synced_at IS NOT NULL AND current_generation = 0',
    );
  }

  Future<void> from55To56(Migrator migrator) async {
    if (!await _columnExists('library_sync_state', 'candidate_generation')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.candidateGeneration,
      );
    }
    if (!await _columnExists('library_sync_state', 'candidate_status')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.candidateStatus,
      );
    }
    if (!await _columnExists('library_sync_state', 'candidate_started_at')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.candidateStartedAt,
      );
    }
    if (!await _columnExists(
      'library_sync_state',
      'candidate_carried_forward_count',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.candidateCarriedForwardCount,
      );
    }
    if (!await _columnExists('library_sync_state', 'last_apply_duration_ms')) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.lastApplyDurationMs,
      );
    }
    if (!await _tableExists('library_sync_candidate_artists')) {
      await migrator.createTable(librarySyncCandidateArtistsTable);
    }
    if (!await _tableExists('library_sync_candidate_albums')) {
      await migrator.createTable(librarySyncCandidateAlbumsTable);
    }
    if (!await _tableExists('library_sync_candidate_songs')) {
      await migrator.createTable(librarySyncCandidateSongsTable);
    }
    if (!await _tableExists('library_sync_local_mutations')) {
      await migrator.createTable(librarySyncLocalMutationsTable);
    }
  }

  Future<void> from56To57(Migrator migrator) async {
    if (!await _columnExists(
      'library_sync_state',
      'last_promotion_diagnostics_json',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.lastPromotionDiagnosticsJson,
      );
    }
    if (!await _columnExists(
      'library_sync_candidate_artists',
      'apply_state',
    )) {
      await migrator.addColumn(
        librarySyncCandidateArtistsTable,
        librarySyncCandidateArtistsTable.applyState,
      );
    }
    if (!await _columnExists(
      'library_sync_candidate_albums',
      'apply_state',
    )) {
      await migrator.addColumn(
        librarySyncCandidateAlbumsTable,
        librarySyncCandidateAlbumsTable.applyState,
      );
    }
    if (!await _columnExists(
      'library_sync_candidate_songs',
      'apply_state',
    )) {
      await migrator.addColumn(
        librarySyncCandidateSongsTable,
        librarySyncCandidateSongsTable.applyState,
      );
    }
  }

  Future<void> from57To58(Migrator migrator) async {
    if (!await _columnExists(
      'app_settings',
      'background_sync_unmetered_only',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.backgroundSyncUnmeteredOnly,
      );
    }
    if (!await _columnExists('library_sync_work', 'work_class')) {
      await migrator.addColumn(
        librarySyncWorkTable,
        librarySyncWorkTable.workClass,
      );
    }
  }

  Future<void> _importLegacyLibrarySyncState() async {
    if (!await _tableExists('server_config') ||
        !await _tableExists('library_sync_state')) {
      return;
    }
    // An interrupted development-era migration can leave the later-added
    // is_authenticated column nullable. Read only the v54 fields needed here;
    // v61 normalizes that column before the app consumes server records.
    final servers =
        await (selectOnly(serverConfigTable)..addColumns(<Expression<Object>>[
              serverConfigTable.id,
              serverConfigTable.capabilities,
              serverConfigTable.lastSynced,
            ]))
            .get();
    for (final server in servers) {
      final serverId = server.read(serverConfigTable.id)!;
      final navis = _readLegacyNavisCapabilities(
        server.read(serverConfigTable.capabilities),
      );
      final lastSynced = server.read(serverConfigTable.lastSynced);
      final cursor = _parseSyncDate(navis['libraryIndexesCursor']);
      final unsupportedAt = _parseSyncDate(
        navis['libraryIndexesUnsupportedAt'],
      );
      final bulkQuery = _legacyString(
        navis['bulkSongSearchWildcardQuery'],
      );
      await into(librarySyncStateTable).insert(
        LibrarySyncStateTableCompanion.insert(
          serverId: Value(serverId),
          conditionalIndexesMode: Value(
            unsupportedAt != null
                ? 'unsupported'
                : cursor != null
                ? 'reliable'
                : 'unknown',
          ),
          bulkSearchMode: Value(
            bulkQuery == null ? 'unknown' : 'supported',
          ),
          bulkSearchQuery: Value(bulkQuery),
          catalogCursor: Value(cursor),
          catalogFingerprint: Value(
            _legacyString(navis['libraryIndexesFingerprint']),
          ),
          lastCheckedAt: Value(lastSynced),
          lastCatalogSyncedAt: Value(lastSynced),
          lastAuxiliarySyncedAt: Value(
            _parseSyncDate(navis['auxiliarySyncLastSyncedAt']),
          ),
          lastGenresSyncedAt: Value(
            _parseSyncDate(navis['genresSyncLastSyncedAt']),
          ),
          lastAuditAt: Value(
            _parseSyncDate(navis['libraryHealthCheckedAt']),
          ),
          auditOffset: Value(
            _legacyInt(navis['libraryPendingIndexesOffset']),
          ),
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  }

  String? _legacyString(Object? value) {
    if (value is! String) {
      return null;
    }
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }

  int _legacyInt(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    return 0;
  }

  Map<String, Object?> _readLegacyNavisCapabilities(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String, Object?>{};
    }
    try {
      final root = jsonDecode(raw);
      if (root is! Map<String, dynamic>) {
        return const <String, Object?>{};
      }
      final navis = root['navis'];
      return navis is Map<String, dynamic> ? navis : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  DateTime? _parseSyncDate(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  Future<void> _clearRetiredGroupListeningSettings() async {
    if (!await _tableExists('app_settings')) {
      return;
    }
    await _ensureGroupListeningColumns();
    if (!await _columnExists('app_settings', 'custom_voyage_servers')) {
      await customStatement('''
        ALTER TABLE app_settings
        ADD COLUMN custom_voyage_servers TEXT;
      ''');
    }
    await customStatement('''
      UPDATE app_settings
      SET group_listening_enabled = 0,
          voyage_server_url = NULL,
          voyage_display_name = NULL,
          voyage_device_label = NULL,
          voyage_auto_follow_host = 1,
          custom_voyage_servers = NULL;
    ''');
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
        showAlbumsPage: const Value(true),
        showRadioPage: const Value(true),
        showPlaylistsPage: const Value(true),
        showArtistsPage: const Value(true),
        showLikedPage: const Value(true),
        libraryPageOrder: const Value(null),
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
        onboardingVersion: const Value(0),
        albumQueueEnabled: const Value(true),
        likedQueueEnabled: const Value(true),
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
      'CREATE INDEX IF NOT EXISTS idx_artists_provisional ON artists(is_provisional, name);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_artists_catalog_generation ON artists(catalog_generation, id);',
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
      'CREATE INDEX IF NOT EXISTS idx_albums_provisional ON albums(is_provisional, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_albums_catalog_generation ON albums(catalog_generation, id);',
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
      'CREATE INDEX IF NOT EXISTS idx_songs_provisional ON songs(is_provisional, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_catalog_generation ON songs(catalog_generation, id);',
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
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_network_usage_operation ON network_usage_events(operation, occurred_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_listenbrainz_weekly_cache_fetched_at ON listenbrainz_weekly_cache(fetched_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_song_identity_aliases_canonical ON song_identity_aliases(canonical_song_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_work_due ON library_sync_work(server_id, status, not_before, priority);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_run_request_active '
      'ON library_sync_run_request(server_id, status, coalescing_key, updated_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_run_attempt_request '
      'ON library_sync_run_attempt(request_id, status, started_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_run_outcome_completed '
      'ON library_sync_run_outcome(completed_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_candidate_albums_pending '
      'ON library_sync_candidate_albums( '
      'server_id, generation, songs_hydrated, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_candidate_songs_album '
      'ON library_sync_candidate_songs( '
      'server_id, generation, album_id, id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS '
      'idx_library_sync_candidate_artists_unclassified '
      'ON library_sync_candidate_artists( '
      'server_id, generation, id) WHERE apply_state IS NULL;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS '
      'idx_library_sync_candidate_albums_unclassified '
      'ON library_sync_candidate_albums( '
      'server_id, generation, id) WHERE apply_state IS NULL;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS '
      'idx_library_sync_candidate_songs_unclassified '
      'ON library_sync_candidate_songs( '
      'server_id, generation, id) WHERE apply_state IS NULL;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_library_sync_local_mutations_entity '
      'ON library_sync_local_mutations(entity_type, entity_id, created_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_starred_absence_candidates_server '
      'ON starred_absence_candidates(server_id, entity_type, last_observed_at);',
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

void _configureNativeDatabase(Database database) {
  database.execute('PRAGMA foreign_keys = ON');
  database.execute('PRAGMA journal_mode = WAL');
  database.execute('PRAGMA busy_timeout = 5000');
}
