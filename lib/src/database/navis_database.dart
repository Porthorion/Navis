import 'package:navis/src/database/tables/annotation_dispatch_lease_table.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:navis/src/database/sync_write_fence.dart';
import 'package:drift/native.dart';
import 'package:navis/src/api/models/artist_ref.dart';
import 'package:navis/src/database/daos/app_settings_dao.dart';
import 'package:navis/src/database/daos/eq_dao.dart';
import 'package:navis/src/database/tables/eq_tables.dart';
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
import 'package:navis/src/database/tables/listenbrainz_feedback_queue_table.dart';
import 'package:navis/src/database/tables/listenbrainz_weekly_cache_table.dart';
import 'package:navis/src/database/tables/library_sync_state_table.dart';
import 'package:navis/src/database/tables/library_sync_work_table.dart';
import 'package:navis/src/database/tables/library_scan_observation_table.dart';
import 'package:navis/src/database/tables/library_recovery_review_table.dart';
import 'package:navis/src/database/tables/entity_identity_aliases_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_albums_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_artists_table.dart';
import 'package:navis/src/database/tables/library_sync_candidate_songs_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';
import 'package:navis/src/database/tables/library_sync_operation_ledger_table.dart';
import 'package:navis/src/database/tables/library_sync_execution_lease_table.dart';
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
import 'package:navis/src/database/tables/song_search_text_table.dart';
import 'package:navis/src/database/tables/album_artist_index_table.dart';
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
    EqPresetsTable,
    EqStateTable,
    ArtistsTable,
    AlbumsTable,
    SongsTable,
    SongSearchTextTable,
    AlbumArtistIndexTable,
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
    AnnotationDispatchLeaseTable,
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
    LibraryScanObservationTable,
    LibraryRecoveryReviewTable,
    EntityIdentityAliasTable,
  ],
  daos: [
    AppSettingsDao,
    EqDao,
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
  new([QueryExecutor? executor])
    : super(_withSyncWriteFence(executor ?? _openConnection()));

  new atPath(String databasePath)
    : this(_openFileConnection(File(databasePath)));

  final _transactionZoneKey = Object();

  /// Replays nested write announcements after the outer WAL commit.
  ///
  /// Drift 2.35 forwards savepoint updates to the root stream store before
  /// commit. Pooled readers can then see old data with no later invalidation.
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    if (Zone.current[_transactionZoneKey] != null) {
      return await super.transaction(action, requireNew: requireNew);
    }

    final updates = <TableUpdate>{};
    // Capture the root store outside Drift's zone, but only listen once this
    // transaction owns the writer lock. Queued transactions must not collect
    // announcements from the transaction ahead of them.
    final rootUpdates = tableUpdates();
    final result = await runZoned(
      () => super.transaction(() async {
        final subscription = rootUpdates.listen(updates.addAll);
        try {
          return await action();
        } finally {
          // Stream.multi forwards root updates asynchronously. Drain the
          // action's pending deliveries before canceling, while still holding
          // the lock and before Drift dispatches this transaction's own tables.
          await Future<void>.microtask(() {});
          // Drift pipes a synchronous broadcast source into Stream.multi.
          // cancel() detaches both listeners synchronously, but its future
          // chains through Dart's root-zone completed future. Awaiting it can
          // strand the commit in FakeAsync after its microtask drain returns.
          unawaited(subscription.cancel());
        }
      }, requireNew: requireNew),
      zoneValues: {_transactionZoneKey: true},
    );
    // Exceptions skip this replay and retain their original stack trace.
    if (updates.isNotEmpty) notifyUpdates(updates);
    return result;
  }

  /// Fences sync writes. A supplied [DatabaseConnection] keeps its own stream
  /// store, so tests can opt into synchronous stream closing.
  static QueryExecutor _withSyncWriteFence(QueryExecutor executor) {
    if (executor is DatabaseConnection) {
      return DatabaseConnection(
        executor.executor.interceptWith(SyncWriteFenceInterceptor()),
        streamQueries: executor.streamQueries,
        connectionData: executor.connectionData,
      );
    }
    return executor.interceptWith(SyncWriteFenceInterceptor());
  }

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
      // candidate catalog. A second reader keeps interactive queries moving
      // while a large catalog read occupies the first reader.
      readPool: 2,
    );
  }

  @override
  int get schemaVersion => 93;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: _createFreshDatabase,
    onUpgrade: (m, from, to) async {
      if (from < 43) {
        await _resetPreReleaseDatabase(m);
        return;
      }
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

  Future<void> _createFreshDatabase(Migrator migrator) async {
    await migrator.createAll();
    await _ensureGroupListeningColumns();
    await _createIndexes();
    await _ensureAppSettingsDefaults();
  }

  Future<void> _resetPreReleaseDatabase(Migrator migrator) async {
    await customStatement('PRAGMA foreign_keys = OFF');
    try {
      await transaction(() async {
        final objects = await customSelect(
          "SELECT type, name FROM sqlite_master WHERE name NOT GLOB 'sqlite_*' "
          "AND type IN ('table', 'index', 'view', 'trigger') "
          "ORDER BY CASE type WHEN 'table' THEN 1 ELSE 0 END",
        ).get();
        for (final object in objects) {
          final type = object.read<String>('type');
          final name = object.read<String>('name').replaceAll('"', '""');
          await customStatement('DROP $type IF EXISTS "$name"');
        }
        await _createFreshDatabase(migrator);
      });
    } finally {
      await customStatement('PRAGMA foreign_keys = ON');
    }
  }

  Future<void> _runMigrations(Migrator migrator, int from, int to) async {
    const firstStepFrom = 43;
    final steps = <Future<void> Function(Migrator)>[
      from43To44,
      from44To45,
      from45To46,
      from46To47,
      from47To48,
      from48To49,
      from49To50,
      from50To51,
      from51To52,
      from52To53,
      from53To54,
      from54To55,
      from55To56,
      from56To57,
      from57To58,
      from58To59,
      from59To60,
      from60To61,
      from61To62,
      from62To63,
      from63To64,
      from64To65,
      from65To66,
      from66To67,
      from67To68,
      from68To69,
      from69To70,
      from70To71,
      from71To72,
      from72To73,
      from73To74,
      from74To75,
      from75To76,
      from76To77,
      from77To78,
      from78To79,
      from79To80,
      from80To81,
      from81To82,
      from82To83,
      from83To84,
      from84To85,
      from85To86,
      from86To87,
      from87To88,
      from88To89,
      from89To90,
      from90To91,
      from91To92,
      from92To93,
    ];
    for (var version = from; version < to; version++) {
      await steps[version - firstStepFrom](migrator);
    }
  }

  Future<void> from92To93(Migrator migrator) async {
    await customStatement('DROP TABLE IF EXISTS library_sync_provider_profile');
    await customStatement('DROP TABLE IF EXISTS library_sync_repair_session');
  }

  /// Clears LRCLIB lyrics selected before edition-aware matching.
  ///
  /// The schema version is the durable marker: newly fetched lyrics and
  /// server lyrics survive subsequent opens and upgrades.
  Future<void> from91To92(Migrator migrator) async {
    await customStatement(
      'DELETE FROM external_lyrics_cache WHERE source IN '
      "('lrclibSynced', 'lrclibPlain', 'lrclib_synced', 'lrclib_plain')",
    );
  }

  /// Adds the external-integration policy: the "Online services" master
  /// switch, the JSON set of disabled services and features, and the one-time
  /// notice flag. The four features that already have a column keep it, so
  /// nothing else moves. An install that scrobbles nothing to ListenBrainz
  /// but holds a valid token turns ListenBrainz feedback off, which keeps
  /// today's coupling of feedback to the scrobbling switch.
  Future<void> from90To91(Migrator migrator) async {
    for (final column in <GeneratedColumn<Object>>[
      appSettingsTable.externalIntegrationsEnabled,
      appSettingsTable.disabledIntegrations,
      appSettingsTable.integrationsNoticeDismissed,
    ]) {
      if (!await _columnExists('app_settings', column.name)) {
        await migrator.addColumn(appSettingsTable, column);
      }
    }
    await customStatement(
      'UPDATE app_settings SET disabled_integrations = '
      "'[\"listenbrainz.feedback\"]' "
      'WHERE listen_brainz_scrobbling_enabled = 0 '
      'AND listen_brainz_token_valid = 1 '
      "AND disabled_integrations = '[]'",
    );
  }

  /// Adds the download preferences: the saved download quality, the
  /// one-time "always download in this quality?" prompt flag, the number of
  /// concurrent downloads, and the global pause. The prompt flag starts false
  /// for every existing install, so each user is asked once.
  Future<void> from89To90(Migrator migrator) async {
    for (final column in <GeneratedColumn<Object>>[
      appSettingsTable.downloadQualityMode,
      appSettingsTable.downloadMaxBitRate,
      appSettingsTable.downloadFormat,
      appSettingsTable.downloadQualityPrompted,
      appSettingsTable.maxConcurrentDownloads,
      appSettingsTable.downloadsPaused,
    ]) {
      if (!await _columnExists('app_settings', column.name)) {
        await migrator.addColumn(appSettingsTable, column);
      }
    }
  }

  /// Records each saved queue row's unshuffled position, so a shuffled
  /// queue restores in the order it was playing and can still be
  /// unshuffled. Existing rows stay null: they were saved in unshuffled
  /// order.
  Future<void> from87To88(Migrator migrator) async {
    if (!await _columnExists(
      'play_queue_items',
      playQueueItemsTable.originalOrder.name,
    )) {
      await migrator.addColumn(
        playQueueItemsTable,
        playQueueItemsTable.originalOrder,
      );
    }
  }

  /// Adds track-matching keys to the derived search index and the derived
  /// album artist index. Both are lazily maintained derived data, so there is
  /// no blocking backfill: existing search rows count as stale until their
  /// keys are written.
  Future<void> from86To87(Migrator migrator) async {
    for (final column in <GeneratedColumn<Object>>[
      songSearchTextTable.matchTitle,
      songSearchTextTable.matchArtist,
      songSearchTextTable.matchAlbum,
    ]) {
      if (!await _columnExists('song_search_text', column.name)) {
        await migrator.addColumn(songSearchTextTable, column);
      }
    }
    if (!await _tableExists('album_artist_index')) {
      await migrator.createTable(albumArtistIndexTable);
    }
  }

  /// Genres are not a Navis concept (product decision 2026-09-30). Drops the
  /// unused genre cache and genre columns, and purges durable genre sync work
  /// so no retired target can be resumed or keep the sync backlog non-empty.
  ///
  /// This step was briefly numbered 87 on a development branch, so a database
  /// from that branch reports version 87 without the track-matching keys (87)
  /// and the saved shuffle order (88). Both steps are idempotent; repeating
  /// them here repairs such a database.
  Future<void> from88To89(Migrator migrator) async {
    await from86To87(migrator);
    await from87To88(migrator);
    await customStatement('DROP TABLE IF EXISTS genres');
    for (final (table, column) in const [
      ('albums', 'genre'),
      ('library_sync_candidate_albums', 'genre'),
      ('library_sync_state', 'last_genres_synced_at'),
    ]) {
      if (await _columnExists(table, column)) {
        await customStatement('ALTER TABLE $table DROP COLUMN $column');
      }
    }
    if (await _tableExists('library_sync_work')) {
      await customStatement(
        "DELETE FROM library_sync_work WHERE entity_id = '@genres'",
      );
    }
    // Run requests store the target-kind enum index; 6 was always the retired
    // genres target and no longer decodes. Dependent attempt and outcome rows
    // are removed explicitly rather than relying on foreign-key enforcement.
    if (await _tableExists('library_sync_run_request')) {
      const retired =
          'SELECT id FROM library_sync_run_request WHERE target_kind = 6';
      await customStatement(
        'DELETE FROM library_sync_run_outcome WHERE request_id IN ($retired)',
      );
      await customStatement(
        'DELETE FROM library_sync_run_attempt WHERE request_id IN ($retired)',
      );
      await customStatement(
        'DELETE FROM library_sync_run_request WHERE target_kind = 6',
      );
    }
  }

  /// Adds the lazily maintained local-search index. Rows are derived data, so
  /// there is no blocking backfill: searches normalize and store stale rows.
  Future<void> from85To86(Migrator migrator) async {
    if (!await _tableExists('song_search_text')) {
      await migrator.createTable(songSearchTextTable);
    }
  }

  Future<void> from84To85(Migrator migrator) async {
    if (!await _columnExists('eq_state', 'workspaces_json')) {
      await migrator.addColumn(eqStateTable, eqStateTable.workspacesJson);
    }
    final rows = await customSelect(
      'SELECT id, configuration_json, selected_preset_id, origin_preset_id FROM eq_state WHERE workspaces_json IS NULL',
    ).get();
    for (final row in rows) {
      final raw = row.readNullable<String>('configuration_json');
      if (raw == null) continue;
      try {
        final curve = jsonDecode(raw) as Map<String, dynamic>;
        final mode = curve['mode'] as String;
        final identity =
            row.readNullable<String>('selected_preset_id') ??
            row.readNullable<String>('origin_preset_id') ??
            'custom';
        await customStatement(
          'UPDATE eq_state SET workspaces_json = ? WHERE id = ?',
          [
            jsonEncode({
              identity: {
                'mode': mode,
                'curves': {mode: curve},
              },
            }),
            row.read<int>('id'),
          ],
        );
      } on FormatException {
        // Retain damaged legacy JSON for repository recovery reporting.
      } on TypeError {
        // Retain malformed legacy shapes as well as malformed JSON.
      }
    }
  }

  Future<void> from83To84(Migrator migrator) async {
    if (!await _tableExists('eq_presets')) {
      await migrator.createTable(eqPresetsTable);
    }
    if (!await _tableExists('eq_state')) {
      await migrator.createTable(eqStateTable);
    }
    final hasLegacy = await _columnExists('app_settings', 'equalizer_enabled');
    var affected = false;
    if (hasLegacy) {
      final row = await customSelect(
        'SELECT equalizer_enabled, loudness_enabled, equalizer_band_gains '
        'FROM app_settings WHERE id = 1',
      ).getSingleOrNull();
      affected =
          row != null &&
          (row.read<int>('equalizer_enabled') != 0 ||
              row.read<int>('loudness_enabled') != 0 ||
              (row.readNullable<String>('equalizer_band_gains')?.isNotEmpty ??
                  false));
    }
    await into(eqStateTable).insert(
      EqStateTableCompanion.insert(
        id: const Value(1),
        legacyResetNotice: Value(affected),
      ),
      mode: InsertMode.insertOrIgnore,
    );
    // SQLite shipped by sqlite3 3.x supports DROP COLUMN. Keeping this narrow
    // preserves raw compatibility columns outside the generated Drift table.
    for (final column in [
      'equalizer_enabled',
      'equalizer_band_gains',
      'loudness_enabled',
      'loudness_target_gain_db',
    ]) {
      if (await _columnExists('app_settings', column)) {
        await customStatement('ALTER TABLE app_settings DROP COLUMN $column');
      }
    }
  }

  Future<void> from82To83(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'lock_pitch_to_speed')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.lockPitchToSpeed,
      );
    }
  }

  Future<void> from81To82(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'playback_pitch_semitones')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.playbackPitchSemitones,
      );
    }
    if (!await _columnExists('app_settings', 'playback_presets')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.playbackPresets,
      );
    }
    if (!await _columnExists('app_settings', 'selected_playback_preset_id')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.selectedPlaybackPresetId,
      );
    }
  }

  Future<void> from80To81(Migrator migrator) async {
    if (!await _columnExists('app_settings', 'grid_artwork_size')) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.gridArtworkSize,
      );
      await customStatement(
        'UPDATE app_settings SET grid_artwork_size = CASE '
        "WHEN album_grid_density IN (1, 2) THEN 'large' "
        "WHEN album_grid_density = 3 THEN 'medium' "
        "WHEN album_grid_density IN (4, 5) THEN 'small' ELSE 'auto' END;",
      );
    }
    if (!await _columnExists(
      'app_settings',
      'home_recommendations_auto_advance',
    )) {
      await migrator.addColumn(
        appSettingsTable,
        appSettingsTable.homeRecommendationsAutoAdvance,
      );
    }
  }

  /// Adds scan observation, typed availability, recovery review, typed
  /// aliases, MusicBrainz identity metadata, and artwork revisions.
  Future<void> from78To79(Migrator migrator) async {
    if (!await _tableExists('library_scan_observation')) {
      await migrator.createTable(libraryScanObservationTable);
    }
    if (!await _tableExists('library_recovery_review')) {
      await migrator.createTable(libraryRecoveryReviewTable);
    }
    if (!await _tableExists('entity_identity_aliases')) {
      await migrator.createTable(entityIdentityAliasTable);
    }
    if (!await _columnExists('songs', 'cover_art_revision')) {
      await migrator.addColumn(songsTable, songsTable.coverArtRevision);
    }
    if (!await _columnExists('songs', 'album_mbid')) {
      await migrator.addColumn(songsTable, songsTable.albumMbid);
    }
    if (!await _columnExists('songs', 'artist_mbid')) {
      await migrator.addColumn(songsTable, songsTable.artistMbid);
    }
    if (!await _columnExists('songs', 'catalog_availability')) {
      await migrator.addColumn(songsTable, songsTable.catalogAvailability);
    }
    if (!await _columnExists('albums', 'cover_art_revision')) {
      await migrator.addColumn(albumsTable, albumsTable.coverArtRevision);
    }
    if (!await _columnExists('albums', 'release_mbid')) {
      await migrator.addColumn(albumsTable, albumsTable.releaseMbid);
    }
    if (!await _columnExists('albums', 'catalog_availability')) {
      await migrator.addColumn(albumsTable, albumsTable.catalogAvailability);
    }
    if (!await _columnExists('artists', 'cover_art_revision')) {
      await migrator.addColumn(artistsTable, artistsTable.coverArtRevision);
    }
    if (!await _columnExists('artists', 'artist_mbid')) {
      await migrator.addColumn(artistsTable, artistsTable.artistMbid);
    }
    if (!await _columnExists('artists', 'catalog_availability')) {
      await migrator.addColumn(artistsTable, artistsTable.catalogAvailability);
    }
    // Existing local-only rows keep their serverDeletedAt marker and local
    // download semantics; typed availability mirrors the same evidence.
    await customStatement(
      "UPDATE songs SET catalog_availability = 'confirmedMissing' "
      'WHERE server_deleted_at IS NOT NULL;',
    );
    // Legacy song aliases stay in song_identity_aliases; copy them into the
    // typed table with a null profile so resolution behavior is unchanged.
    await customStatement('''
      INSERT OR IGNORE INTO entity_identity_aliases
        (server_id, entity_type, old_id, new_id, match_reason, matched_at)
      SELECT NULL, 'song', old_song_id, canonical_song_id, match_reason, matched_at
      FROM song_identity_aliases;
    ''');
  }

  /// Adds MusicBrainz release/artist identifiers to the candidate staging
  /// tables so OpenSubsonic stable IDs survive promotion into the committed
  /// catalog rows, enabling album/artist relinking.
  Future<void> from79To80(Migrator migrator) async {
    if (!await _columnExists('library_sync_candidate_albums', 'release_mbid')) {
      await migrator.addColumn(
        librarySyncCandidateAlbumsTable,
        librarySyncCandidateAlbumsTable.releaseMbid,
      );
    }
    if (!await _columnExists('library_sync_candidate_artists', 'artist_mbid')) {
      await migrator.addColumn(
        librarySyncCandidateArtistsTable,
        librarySyncCandidateArtistsTable.artistMbid,
      );
    }
  }

  Future<void> from77To78(Migrator migrator) async {
    if (!await _columnExists(
      'library_sync_state',
      'initial_catalog_usable_at',
    )) {
      await migrator.addColumn(
        librarySyncStateTable,
        librarySyncStateTable.initialCatalogUsableAt,
      );
    }
  }

  Future<void> from76To77(Migrator migrator) async {
    if (!await _columnExists('library_sync_run_attempt', 'telemetry_json')) {
      await migrator.addColumn(
        librarySyncRunAttemptTable,
        librarySyncRunAttemptTable.telemetryJson,
      );
    }
  }

  Future<void> from75To76(Migrator migrator) async {
    await customStatement(
      'CREATE TEMP TABLE playlist_membership_v75 AS SELECT * FROM playlist_songs',
    );
    await migrator.deleteTable('playlist_songs');
    await migrator.createTable(playlistSongsTable);
    // Legacy rows can share a sort index. Preserve every row in a stable order.
    await customStatement(
      'INSERT INTO playlist_songs (playlist_id, song_id, sort_order) '
      'SELECT playlist_id, song_id, ROW_NUMBER() OVER ( '
      'PARTITION BY playlist_id ORDER BY sort_order, song_id) - 1 FROM playlist_membership_v75',
    );
    await customStatement('DROP TABLE playlist_membership_v75');
    if (!await _tableExists('annotation_dispatch_lease')) {
      await migrator.createTable(annotationDispatchLeaseTable);
    }
  }

  Future<void> from74To75(Migrator migrator) async {
    if (!await _columnExists('albums', 'songs_verified_at')) {
      await migrator.addColumn(albumsTable, albumsTable.songsVerifiedAt);
    }
  }

  Future<void> from73To74(Migrator migrator) async {
    for (final column in [
      starSyncQueueTable.operation,
      starSyncQueueTable.attemptCount,
      starSyncQueueTable.notBefore,
      starSyncQueueTable.lastErrorType,
    ]) {
      if (!await _columnExists('star_sync_queue', column.$name)) {
        await migrator.addColumn(starSyncQueueTable, column);
      }
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
    if (!await _columnExists('library_sync_state', 'android_worker_result')) {
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
    if (!await _columnExists('app_settings', 'desktop_last_audible_volume')) {
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
    if (!await _columnExists('library_sync_candidate_artists', 'apply_state')) {
      await migrator.addColumn(
        librarySyncCandidateArtistsTable,
        librarySyncCandidateArtistsTable.applyState,
      );
    }
    if (!await _columnExists('library_sync_candidate_albums', 'apply_state')) {
      await migrator.addColumn(
        librarySyncCandidateAlbumsTable,
        librarySyncCandidateAlbumsTable.applyState,
      );
    }
    if (!await _columnExists('library_sync_candidate_songs', 'apply_state')) {
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
      final bulkQuery = _legacyString(navis['bulkSongSearchWildcardQuery']);
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
          bulkSearchMode: Value(bulkQuery == null ? 'unknown' : 'supported'),
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
          lastAuditAt: Value(_parseSyncDate(navis['libraryHealthCheckedAt'])),
          auditOffset: Value(_legacyInt(navis['libraryPendingIndexesOffset'])),
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
    // Reverse lookups by song. These are also the child side of cascading
    // foreign keys, so without them every song delete scans the table.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_playlist_songs_song ON playlist_songs(song_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_play_queue_items_song ON play_queue_items(song_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_artist ON songs(artist_id);',
    );
    // Exact lookups on the derived search index: track-matching title and
    // artist keys, and title-then-artist prefixes for downloads-folder
    // matching.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_song_search_text_match_title '
      'ON song_search_text(match_title);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_song_search_text_match_artist '
      'ON song_search_text(match_artist);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_song_search_text_search '
      'ON song_search_text(search_text);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_songs_starred ON songs(starred) WHERE starred IS NOT NULL;',
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

  /// Low-priority maintenance run after startup: refresh bounded planner
  /// statistics and the local-search index. Safe to call repeatedly.
  Future<void> runDeferredMaintenance() async {
    await customStatement('PRAGMA analysis_limit = 400');
    await customStatement('PRAGMA optimize');
    await libraryDao.scheduleSongSearchIndexRefresh();
    await libraryDao.refreshAlbumArtistIndex();
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
  // WAL with synchronous=NORMAL is corruption-safe; only the last commits can
  // be lost on an OS crash or power loss, never on an app kill. It avoids an
  // fsync on every commit.
  database.execute('PRAGMA synchronous = NORMAL');
  // 8 MiB page cache per connection (the default is 2 MiB) for a catalog of
  // tens of thousands of rows, sorts in memory, and a bounded WAL file after
  // large catalog promotions.
  database.execute('PRAGMA cache_size = -8192');
  database.execute('PRAGMA temp_store = MEMORY');
  database.execute('PRAGMA journal_size_limit = 67108864');
}

/// Routes DAO transactions through the database's post-commit invalidation.
mixin NavisDaoTransactions on DatabaseAccessor<NavisDatabase> {
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => attachedDatabase.transaction(action, requireNew: requireNew);
}
