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

  Future<List<PlaylistsTableData>> getAllPlaylists() {
    return select(playlistsTable).get();
  }

  Future<Map<String, int>> getPlaylistSongCounts() async {
    final count = playlistSongsTable.songId.count();
    final rows =
        await (selectOnly(playlistSongsTable)
              ..addColumns([playlistSongsTable.playlistId, count])
              ..groupBy([playlistSongsTable.playlistId]))
            .get();
    return <String, int>{
      for (final row in rows)
        row.read(playlistSongsTable.playlistId)!: row.read(count) ?? 0,
    };
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
          onConflict: DoUpdate(
            (old) => playlist,
            target: [playlistsTable.id],
          ),
        );
      }
    });
  }

  Future<void> reconcileServerPlaylists(
    List<PlaylistsTableCompanion> playlists,
    List<String> serverIds,
  ) async {
    await transaction(() async {
      await upsertPlaylists(playlists);
      if (serverIds.isEmpty) {
        await delete(playlistSongsTable).go();
        await delete(playlistsTable).go();
        return;
      }
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.isNotIn(serverIds))).go();
      await (delete(
        playlistsTable,
      )..where((table) => table.id.isNotIn(serverIds))).go();
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

  Future<void> replaceHydratedPlaylist(
    PlaylistsTableCompanion playlist,
    List<SongsTableCompanion> songs,
    List<PlaylistSongsTableCompanion> joins,
  ) async {
    await transaction(() async {
      await into(playlistsTable).insert(
        playlist,
        onConflict: DoUpdate((old) => playlist, target: [playlistsTable.id]),
      );
      if (songs.isNotEmpty) {
        await batch((batch) {
          for (final song in songs) {
            final canonical = song.copyWith(
              serverDeletedAt: const Value(null),
              isProvisional: Value(
                song.isExternal.present && song.isExternal.value,
              ),
            );
            batch.insert(
              songsTable,
              canonical,
              onConflict: DoUpdate(
                (old) => canonical,
                target: [songsTable.id],
              ),
            );
          }
        });
      }
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.equals(playlist.id.value))).go();
      if (joins.isNotEmpty) {
        await batch((batch) => batch.insertAll(playlistSongsTable, joins));
      }
    });
  }

  Future<void> clearAllPlaylists() async {
    await transaction(() async {
      await delete(playlistSongsTable).go();
      await delete(playlistsTable).go();
    });
  }

  /// Delete a single playlist and its song associations.
  Future<void> deletePlaylist(String playlistId) async {
    await transaction(() async {
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.equals(playlistId))).go();
      await (delete(
        playlistsTable,
      )..where((table) => table.id.equals(playlistId))).go();
    });
  }

  /// Remove playlists whose IDs are NOT in [keepIds].
  ///
  /// Used during server sync to prune locally cached playlists that have been
  /// deleted on the server.
  Future<void> deletePlaylistsNotIn(List<String> keepIds) async {
    if (keepIds.isEmpty) {
      await clearAllPlaylists();
      return;
    }
    await transaction(() async {
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.isNotIn(keepIds))).go();
      await (delete(
        playlistsTable,
      )..where((table) => table.id.isNotIn(keepIds))).go();
    });
  }

  /// Watch a single playlist by ID.
  Stream<PlaylistsTableData?> watchPlaylistById(String playlistId) {
    final query = select(playlistsTable)
      ..where((table) => table.id.equals(playlistId));
    return query.watchSingleOrNull();
  }
}
