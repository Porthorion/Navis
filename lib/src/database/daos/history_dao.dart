import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/recent_searches_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'history_dao.g.dart';

@DriftAccessor(
  tables: [PlayHistoryTable, RecentSearchesTable, SongsTable, AlbumsTable],
)
class HistoryDao extends DatabaseAccessor<NavisDatabase>
    with _$HistoryDaoMixin {
  HistoryDao(super.db);

  Stream<List<PlayHistoryTableData>> watchPlayHistory({int limit = 100}) {
    final query = select(playHistoryTable)
      ..orderBy([(table) => OrderingTerm.desc(table.playedAt)])
      ..limit(limit);
    return query.watch();
  }

  Future<void> addPlayHistory(String songId) async {
    await into(playHistoryTable).insert(
      PlayHistoryTableCompanion.insert(
        songId: songId,
        playedAt: DateTime.now(),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Stream<List<SongsTableData>> watchRecentlyPlayedSongs({int limit = 20}) {
    // Over-fetch to compensate for duplicate song entries, then
    // deduplicate in Dart so each song appears only once (most recent
    // play wins) and replayed songs are pushed to the front of the list.
    final query =
        select(playHistoryTable).join([
            innerJoin(
              songsTable,
              songsTable.id.equalsExp(playHistoryTable.songId),
            ),
          ])
          ..orderBy([OrderingTerm.desc(playHistoryTable.playedAt)])
          ..limit(limit * 5);

    return query.watch().map((rows) {
      final seen = <String>{};
      final songs = <SongsTableData>[];
      for (final row in rows) {
        final song = row.readTable(songsTable);
        if (seen.add(song.id)) {
          songs.add(song);
          if (songs.length >= limit) break;
        }
      }
      return songs;
    });
  }

  /// Watch recently played **albums** by deriving them from play history.
  ///
  /// Joins play_history → songs → albums, deduplicates by album ID and
  /// returns distinct albums in most-recently-played order.
  Stream<List<AlbumsTableData>> watchRecentlyPlayedAlbums({int? limit = 20}) {
    final query = select(playHistoryTable).join([
      innerJoin(
        songsTable,
        songsTable.id.equalsExp(playHistoryTable.songId),
      ),
      innerJoin(
        albumsTable,
        albumsTable.id.equalsExp(songsTable.albumId),
      ),
    ])..orderBy([OrderingTerm.desc(playHistoryTable.playedAt)]);
    if (limit != null) {
      query.limit(limit * 5);
    }

    return query.watch().map((rows) {
      final seen = <String>{};
      final albums = <AlbumsTableData>[];
      for (final row in rows) {
        final album = row.readTable(albumsTable);
        if (seen.add(album.id)) {
          albums.add(album);
          if (limit != null && albums.length >= limit) break;
        }
      }
      return albums;
    });
  }

  Stream<List<RecentSearchesTableData>> watchRecentSearches({int limit = 20}) {
    final query = select(recentSearchesTable)
      ..orderBy([(table) => OrderingTerm.desc(table.searchedAt)])
      ..limit(limit);
    return query.watch();
  }

  Future<void> saveSearchQuery(String queryText) {
    return into(recentSearchesTable).insertOnConflictUpdate(
      RecentSearchesTableCompanion(
        query: Value(queryText),
        searchedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> clearAllHistory() async {
    await transaction(() async {
      await delete(playHistoryTable).go();
      await delete(recentSearchesTable).go();
    });
  }
}
