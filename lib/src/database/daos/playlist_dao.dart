import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/playlist_songs_table.dart';
import 'package:navis/src/database/tables/playlists_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'playlist_dao.g.dart';

@DriftAccessor(tables: [PlaylistsTable, PlaylistSongsTable, SongsTable])
class PlaylistDao extends DatabaseAccessor<NavisDatabase>
    with _$PlaylistDaoMixin {
  PlaylistDao(super.db);

  Stream<List<PlaylistsTableData>> watchPlaylists() {
    final query = select(playlistsTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    return query.watch();
  }

  Stream<List<SongsTableData>> watchPlaylistSongs(String playlistId) {
    final query =
        select(songsTable).join([
            innerJoin(
              playlistSongsTable,
              playlistSongsTable.songId.equalsExp(songsTable.id),
            ),
          ])
          ..where(playlistSongsTable.playlistId.equals(playlistId))
          ..orderBy([
            OrderingTerm.asc(playlistSongsTable.sortOrder),
          ]);

    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(songsTable)).toList(),
    );
  }

  Future<void> upsertPlaylists(List<PlaylistsTableCompanion> playlists) async {
    await batch((batch) {
      for (final playlist in playlists) {
        batch.insert(
          playlistsTable,
          playlist,
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> replacePlaylistSongs(
    String playlistId,
    List<PlaylistSongsTableCompanion> songs,
  ) async {
    await transaction(() async {
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.equals(playlistId))).go();
      if (songs.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(playlistSongsTable, songs);
        });
      }
    });
  }
}
