import 'package:collection/collection.dart';
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

  /// Each device playlist's first four distinct song covers, in playlist
  /// order, for its mosaic. One grouped query for all device playlists;
  /// playlists without a song cover are absent.
  Stream<Map<String, List<String>>> watchLocalPlaylistCoverArtIds() {
    final firstAt = playlistSongsTable.sortOrder.min();
    final query =
        selectOnly(playlistSongsTable).join([
            innerJoin(
              songsTable,
              songsTable.id.equalsExp(playlistSongsTable.songId),
            ),
            innerJoin(
              playlistsTable,
              playlistsTable.id.equalsExp(playlistSongsTable.playlistId),
            ),
          ])
          ..addColumns([playlistSongsTable.playlistId, songsTable.coverArt])
          ..where(
            playlistsTable.isLocal.equals(true) &
                songsTable.coverArt.isNotNull(),
          )
          ..groupBy([playlistSongsTable.playlistId, songsTable.coverArt])
          ..orderBy([
            OrderingTerm.asc(playlistSongsTable.playlistId),
            OrderingTerm.asc(firstAt),
          ]);
    query.addColumns([firstAt]);
    return query
        .watch()
        .map((rows) {
          final covers = <String, List<String>>{};
          for (final row in rows) {
            final ids = covers.putIfAbsent(
              row.read(playlistSongsTable.playlistId)!,
              () => [],
            );
            if (ids.length < 4) ids.add(row.read(songsTable.coverArt)!);
          }
          return covers;
        })
        .distinct(
          const MapEquality<String, List<String>>(
            values: ListEquality<String>(),
          ).equals,
        );
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

  /// Monotonic journal boundary captured before fetching server headers.
  Future<int> getMutationVersion() async {
    final table = attachedDatabase.librarySyncLocalMutationsTable;
    final latest = table.id.max();
    final row = await (attachedDatabase.selectOnly(
      table,
    )..addColumns([latest])).getSingle();
    final version = row.read(latest) ?? 0;
    return version;
  }

  Future<void> _recordWrite(String id) async {
    final table = attachedDatabase.librarySyncLocalMutationsTable;
    await (attachedDatabase.delete(table)..where(
          (row) => row.entityType.equals('playlist') & row.entityId.equals(id),
        ))
        .go();
    await attachedDatabase
        .into(table)
        .insert(
          LibrarySyncLocalMutationsTableCompanion.insert(
            entityType: 'playlist',
            entityId: id,
            operation: 'upsert',
            createdAt: DateTime.now(),
          ),
        );
  }

  Future<void> upsertPlaylists(List<PlaylistsTableCompanion> playlists) async {
    await transaction(() async {
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
      for (final playlist in playlists) {
        await _recordWrite(playlist.id.value);
      }
    });
  }

  Future<List<String>> reconcileServerPlaylists(
    List<PlaylistsTableCompanion> playlists,
    List<String> serverIds, {
    int? mutationVersion,
  }) => transaction(() async {
    final table = attachedDatabase.librarySyncLocalMutationsTable;
    final mutations = mutationVersion == null
        ? <LibrarySyncLocalMutationsTableData>[]
        : await (attachedDatabase.select(table)..where(
                (row) =>
                    row.entityType.equals('playlist') &
                    row.id.isBiggerThanValue(mutationVersion),
              ))
              .get();
    final protected = mutations.map((row) => row.entityId).toSet();
    await upsertPlaylists([
      for (final playlist in playlists)
        if (!protected.contains(playlist.id.value)) playlist,
    ]);
    final removed =
        await (select(playlistsTable)..where(
              (row) =>
                  row.isLocal.equals(false) &
                  row.id.isNotIn([...serverIds, ...protected]),
            ))
            .get();
    final removedIds = removed.map((row) => row.id).toList();
    await (delete(
      playlistSongsTable,
    )..where((row) => row.playlistId.isIn(removedIds))).go();
    await (delete(
      playlistsTable,
    )..where((row) => row.id.isIn(removedIds))).go();
    await (attachedDatabase.delete(table)..where(
          (row) =>
              row.entityType.equals('playlist') & row.entityId.isIn(removedIds),
        ))
        .go();
    return removedIds;
  });

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
      await _recordWrite(playlist.id.value);
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

  /// Stores the server's actual contents and removes the device copy only
  /// when its name and ordered entries still match the uploaded snapshot.
  Future<bool> replaceLocalWithServer(
    String localId,
    PlaylistsTableCompanion server, {
    required String uploadedName,
    required List<String> uploadedSongIds,
    required List<SongsTableCompanion> songs,
    required List<String> serverSongIds,
  }) {
    return transaction(() async {
      final local = await (select(
        playlistsTable,
      )..where((row) => row.id.equals(localId))).getSingleOrNull();
      final joins =
          await (select(playlistSongsTable)
                ..where((row) => row.playlistId.equals(localId))
                ..orderBy([(row) => OrderingTerm.asc(row.sortOrder)]))
              .get();
      final unchanged =
          local != null &&
          local.isLocal &&
          local.name == uploadedName &&
          const ListEquality<String>().equals(
            joins.map((row) => row.songId).toList(),
            uploadedSongIds,
          );
      await replaceHydratedPlaylist(server, songs, [
        for (var index = 0; index < serverSongIds.length; index++)
          PlaylistSongsTableCompanion.insert(
            playlistId: server.id.value,
            songId: serverSongIds[index],
            sortOrder: index,
          ),
      ]);
      if (unchanged) await deletePlaylist(localId);
      return !unchanged;
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
      final mutations = attachedDatabase.librarySyncLocalMutationsTable;
      await (attachedDatabase.delete(mutations)..where(
            (row) =>
                row.entityType.equals('playlist') &
                row.entityId.equals(playlistId),
          ))
          .go();
    });
  }

  /// Watch a single playlist by ID.
  Stream<PlaylistsTableData?> watchPlaylistById(String playlistId) {
    final query = select(playlistsTable)
      ..where((table) => table.id.equals(playlistId));
    return query.watchSingleOrNull();
  }
}
