import 'package:drift/drift.dart';
import 'package:navis/src/database/database_utils.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/playlist_songs_table.dart';
import 'package:navis/src/database/tables/playlists_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';
import 'package:uuid/uuid.dart';

part 'playlist_dao.g.dart';

@DriftAccessor(tables: [PlaylistsTable, PlaylistSongsTable, SongsTable])
class PlaylistDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$PlaylistDaoMixin {
  new(super.attachedDatabase);

  Stream<List<PlaylistsTableData>> watchPlaylists() {
    final query = select(playlistsTable)
      ..orderBy([
        (table) => OrderingTerm.asc(table.name.collate(Collate.noCase)),
      ]);
    return query.watch();
  }

  Future<List<PlaylistsTableData>> getServerPlaylists() {
    return (select(
      playlistsTable,
    )..where((table) => table.isLocal.equals(false))).get();
  }

  Future<String> createLocalPlaylist(String name, List<String> songIds) {
    return transaction(() async {
      final id = 'local:${const Uuid().v4()}';
      await into(playlistsTable).insert(
        PlaylistsTableCompanion.insert(
          id: id,
          name: name,
          isLocal: const Value(true),
        ),
      );
      await setLocalPlaylistSongs(id, songIds);
      return id;
    });
  }

  Future<void> renamePlaylist(String id, String name) {
    return (update(playlistsTable)
          ..where((table) => table.id.equals(id) & table.isLocal.equals(true)))
        .write(PlaylistsTableCompanion(name: Value(name)));
  }

  /// Replaces device playlist occurrences and returns the number not in songs.
  Future<int> setLocalPlaylistSongs(String id, List<String> songIds) {
    return transaction(() async {
      final playlist =
          await (select(playlistsTable)..where(
                (table) => table.id.equals(id) & table.isLocal.equals(true),
              ))
              .getSingleOrNull();
      if (playlist == null) throw StateError('Device playlist does not exist.');
      final songsById = <String, SongsTableData>{};
      for (final ids in chunked(songIds.toSet().toList(), 500)) {
        final songs = await (select(
          songsTable,
        )..where((table) => table.id.isIn(ids))).get();
        for (final song in songs) {
          songsById[song.id] = song;
        }
      }
      final songs = [for (final id in songIds) ?songsById[id]];
      await replacePlaylistSongs(id, [
        for (var index = 0; index < songs.length; index++)
          PlaylistSongsTableCompanion.insert(
            playlistId: id,
            songId: songs[index].id,
            sortOrder: index,
          ),
      ]);
      await (update(
        playlistsTable,
      )..where((table) => table.id.equals(id))).write(
        PlaylistsTableCompanion(
          songCount: Value(songs.length),
          duration: Value(
            songs.fold<int>(0, (sum, song) => sum + (song.duration ?? 0)),
          ),
          coverArt: Value(songs.firstOrNull?.coverArt),
        ),
      );
      return songIds.length - songs.length;
    });
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
          ..orderBy([OrderingTerm.asc(playlistSongsTable.sortOrder)]);

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
          onConflict: DoUpdate((old) => playlist, target: [playlistsTable.id]),
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
      final removedPlaylists = selectOnly(playlistsTable)
        ..addColumns([playlistsTable.id])
        ..where(playlistsTable.isLocal.equals(false));
      if (serverIds.isNotEmpty) {
        removedPlaylists.where(playlistsTable.id.isNotIn(serverIds));
      }
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.isInQuery(removedPlaylists))).go();
      await (delete(playlistsTable)..where(
            (table) =>
                table.isLocal.equals(false) & table.id.isNotIn(serverIds),
          ))
          .go();
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
    List<PlaylistSongsTableCompanion> joins, {
    DateTime? snapshotStartedAt,
  }) async {
    await transaction(() async {
      await into(playlistsTable).insert(
        playlist,
        onConflict: DoUpdate((old) => playlist, target: [playlistsTable.id]),
      );
      await attachedDatabase.libraryDao.upsertSongs(
        songs,
        snapshotStartedAt: snapshotStartedAt,
      );
      await (delete(
        playlistSongsTable,
      )..where((table) => table.playlistId.equals(playlist.id.value))).go();
      if (joins.isNotEmpty) {
        await batch((batch) => batch.insertAll(playlistSongsTable, joins));
      }
    });
  }

  /// Replaces device playlist [localId] with [server] in one transaction: the
  /// server row takes over the ordered songs and the device row is deleted.
  Future<void> replaceLocalWithServer(
    String localId,
    PlaylistsTableCompanion server,
  ) {
    return transaction(() async {
      final joins =
          await (select(playlistSongsTable)
                ..where((table) => table.playlistId.equals(localId))
                ..orderBy([(table) => OrderingTerm.asc(table.sortOrder)]))
              .get();
      await into(playlistsTable).insert(
        server,
        onConflict: DoUpdate((old) => server, target: [playlistsTable.id]),
      );
      await replacePlaylistSongs(server.id.value, [
        for (final join in joins)
          PlaylistSongsTableCompanion.insert(
            playlistId: server.id.value,
            songId: join.songId,
            sortOrder: join.sortOrder,
          ),
      ]);
      await deletePlaylist(localId);
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

  /// Watch a single playlist by ID.
  Stream<PlaylistsTableData?> watchPlaylistById(String playlistId) {
    final query = select(playlistsTable)
      ..where((table) => table.id.equals(playlistId));
    return query.watchSingleOrNull();
  }
}
