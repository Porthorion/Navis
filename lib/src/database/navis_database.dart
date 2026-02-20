import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:navis/src/database/daos/cache_dao.dart';
import 'package:navis/src/database/daos/download_queue_dao.dart';
import 'package:navis/src/database/daos/history_dao.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/daos/play_queue_dao.dart';
import 'package:navis/src/database/daos/playlist_dao.dart';
import 'package:navis/src/database/daos/server_dao.dart';
import 'package:navis/src/database/tables/albums_table.dart';
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
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/server_config_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'navis_database.g.dart';

@DriftDatabase(
  tables: [
    ServerConfigTable,
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
  ],
  daos: [
    ServerDao,
    LibraryDao,
    PlaylistDao,
    CacheDao,
    DownloadQueueDao,
    HistoryDao,
    PlayQueueDao,
  ],
)
class NavisDatabase extends _$NavisDatabase {
  NavisDatabase([QueryExecutor? executor])
    : super(executor ?? _openConnection());

  static QueryExecutor _openConnection() => driftDatabase(name: 'navis.sqlite');

  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await _createIndexes();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await _runMigrations(m, from, to);
      await _createIndexes();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
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
  }

  Future<void> from1To2(Migrator migrator) async {
    await migrator.addColumn(
      serverConfigTable,
      serverConfigTable.lastFullSynced,
    );
  }

  Future<void> from2To3(Migrator migrator) async {
    await migrator.addColumn(
      albumsTable,
      albumsTable.songsHydrated,
    );
    await backfillAlbumHydrationState();
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
      'CREATE INDEX IF NOT EXISTS idx_playlist_songs_order ON playlist_songs(playlist_id, sort_order);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_play_queue_items_order ON play_queue_items(queue_id, sort_order);',
    );
  }
}
