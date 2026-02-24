import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'library_dao.g.dart';

enum AlbumSortOrder { newest, name, artist }

enum SongSortOrder { newest, oldest, name }

@DriftAccessor(tables: [ArtistsTable, AlbumsTable, SongsTable, GenresTable])
class LibraryDao extends DatabaseAccessor<NavisDatabase>
    with _$LibraryDaoMixin {
  LibraryDao(super.db);

  Stream<List<ArtistsTableData>> watchArtists() {
    final query = select(artistsTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    return query.watch();
  }

  Stream<List<AlbumsTableData>> watchAlbumsByArtist(String artistId) {
    final query = select(albumsTable)
      ..where((table) => table.artistId.equals(artistId))
      ..orderBy([
        (table) => OrderingTerm.asc(table.year),
        (table) => OrderingTerm.asc(table.name),
      ]);
    return query.watch();
  }

  Stream<ArtistsTableData?> watchArtistById(String artistId) {
    final query = select(artistsTable)
      ..where((table) => table.id.equals(artistId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<AlbumsTableData>> watchAllAlbums() {
    final query = _orderedAlbumsQuery(AlbumSortOrder.newest);
    return query.watch();
  }

  Stream<int> watchAlbumCount() {
    final countExpression = albumsTable.id.count();
    final query = selectOnly(albumsTable)..addColumns([countExpression]);
    return query.watchSingle().map((row) => row.read(countExpression) ?? 0);
  }

  Stream<List<AlbumsTableData>> watchAlbumsPage({
    required AlbumSortOrder sort,
    required int limit,
    int offset = 0,
  }) {
    final query = _orderedAlbumsQuery(sort)
      ..limit(
        limit < 1 ? 1 : limit,
        offset: offset < 0 ? 0 : offset,
      );
    return query.watch();
  }

  Stream<AlbumsTableData?> watchAlbumById(String albumId) {
    final query = select(albumsTable)
      ..where((table) => table.id.equals(albumId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<SongsTableData>> watchSongsByAlbum(String albumId) {
    final query = select(songsTable)
      ..where((table) => table.albumId.equals(albumId))
      ..orderBy([
        (table) => OrderingTerm.asc(table.discNumber),
        (table) => OrderingTerm.asc(table.track),
      ]);
    return query.watch();
  }

  Stream<SongsTableData?> watchSongById(String songId) {
    final query = select(songsTable)
      ..where((table) => table.id.equals(songId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<SongsTableData>> watchAllSongs() {
    return watchSongsSorted(SongSortOrder.newest);
  }

  Stream<List<SongsTableData>> watchSongsSorted(SongSortOrder sort) {
    final query = select(songsTable);
    switch (sort) {
      case SongSortOrder.newest:
        query.orderBy([
          (table) => OrderingTerm.asc(table.createdAt.isNull()),
          (table) => OrderingTerm.desc(table.createdAt),
          (table) => OrderingTerm.asc(table.title),
          (table) => OrderingTerm.asc(table.id),
        ]);
      case SongSortOrder.oldest:
        query.orderBy([
          (table) => OrderingTerm.asc(table.createdAt.isNull()),
          (table) => OrderingTerm.asc(table.createdAt),
          (table) => OrderingTerm.asc(table.title),
          (table) => OrderingTerm.asc(table.id),
        ]);
      case SongSortOrder.name:
        query.orderBy([
          (table) => OrderingTerm.asc(table.title),
          (table) => OrderingTerm.asc(table.id),
        ]);
    }
    return query.watch();
  }

  Stream<List<GenresTableData>> watchGenres() {
    final query = select(genresTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    return query.watch();
  }

  Stream<List<AlbumsTableData>> watchAlbumsByGenre(String genre) {
    final query = select(albumsTable)
      ..where((table) => table.genre.equals(genre))
      ..orderBy([
        (table) => OrderingTerm.desc(table.year),
        (table) => OrderingTerm.asc(table.name),
      ]);
    return query.watch();
  }

  Stream<List<SongsTableData>> watchSongsByGenre(String genre) {
    final query =
        select(songsTable).join([
            innerJoin(
              albumsTable,
              albumsTable.id.equalsExp(songsTable.albumId),
            ),
          ])
          ..where(albumsTable.genre.equals(genre))
          ..orderBy([
            OrderingTerm.asc(songsTable.artistName),
            OrderingTerm.asc(songsTable.albumName),
            OrderingTerm.asc(songsTable.track),
          ]);
    return query.watch().map(
      (rows) => rows.map((row) => row.readTable(songsTable)).toList(),
    );
  }

  Future<void> replaceArtists(List<ArtistsTableCompanion> artists) async {
    await transaction(() async {
      await delete(artistsTable).go();
      await batch((batch) {
        batch.insertAll(artistsTable, artists);
      });
    });
  }

  Future<void> upsertArtists(List<ArtistsTableCompanion> artists) async {
    if (artists.isEmpty) {
      return;
    }
    await batch((batch) {
      for (final artist in artists) {
        batch.insert(
          artistsTable,
          artist,
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> replaceAlbums(List<AlbumsTableCompanion> albums) async {
    await transaction(() async {
      await delete(albumsTable).go();
      await batch((batch) {
        batch.insertAll(albumsTable, albums);
      });
    });
  }

  Future<void> upsertAlbums(List<AlbumsTableCompanion> albums) async {
    if (albums.isEmpty) {
      return;
    }
    await batch((batch) {
      for (final album in albums) {
        batch.insert(
          albumsTable,
          album,
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> replaceSongs(List<SongsTableCompanion> songs) async {
    await transaction(() async {
      await delete(songsTable).go();
      await batch((batch) {
        batch.insertAll(songsTable, songs);
      });
    });
  }

  Future<void> replaceSongsForAlbum(
    String albumId,
    List<SongsTableCompanion> songs,
  ) async {
    await transaction(() async {
      await (delete(
        songsTable,
      )..where((table) => table.albumId.equals(albumId))).go();
      if (songs.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(songsTable, songs);
      });
    });
  }

  Future<void> replaceSongsForAlbumsChunk(
    Map<String, List<SongsTableCompanion>> songsByAlbumId,
  ) async {
    final albumIds = songsByAlbumId.keys
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (albumIds.isEmpty) {
      return;
    }

    final songs = songsByAlbumId.values.expand((rows) => rows).toList();
    await transaction(() async {
      await (delete(
        songsTable,
      )..where((table) => table.albumId.isIn(albumIds))).go();
      if (songs.isEmpty) {
        return;
      }
      await batch((batch) {
        batch.insertAll(songsTable, songs);
      });
    });
  }

  Future<void> upsertSongs(List<SongsTableCompanion> songs) async {
    if (songs.isEmpty) {
      return;
    }
    await batch((batch) {
      for (final song in songs) {
        batch.insert(
          songsTable,
          song,
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Future<void> replaceGenres(List<GenresTableCompanion> genres) async {
    await transaction(() async {
      await delete(genresTable).go();
      await batch((batch) {
        batch.insertAll(genresTable, genres);
      });
    });
  }

  /// Update only the [starred] column for a single album row.
  Future<void> updateAlbumStarred(String albumId, DateTime? starred) {
    return (update(albumsTable)..where((t) => t.id.equals(albumId))).write(
      AlbumsTableCompanion(starred: Value(starred)),
    );
  }

  /// Update only the [starred] column for a single artist row.
  Future<void> updateArtistStarred(String artistId, DateTime? starred) {
    return (update(artistsTable)..where((t) => t.id.equals(artistId))).write(
      ArtistsTableCompanion(starred: Value(starred)),
    );
  }

  /// Update only the [starred] column for a single song row.
  Future<void> updateSongStarred(String songId, DateTime? starred) {
    return (update(songsTable)..where((t) => t.id.equals(songId))).write(
      SongsTableCompanion(starred: Value(starred)),
    );
  }

  /// Watch songs that have been starred/liked, ordered by starred date
  /// (most recently starred first).
  Stream<List<SongsTableData>> watchStarredSongs({int limit = 5}) {
    final query = select(songsTable)
      ..where((t) => t.starred.isNotNull())
      ..orderBy([(t) => OrderingTerm.desc(t.starred)])
      ..limit(limit);
    return query.watch();
  }

  /// Watch all starred songs (no limit) for the full liked-tracks view.
  Stream<List<SongsTableData>> watchAllStarredSongs() {
    final query = select(songsTable)
      ..where((t) => t.starred.isNotNull())
      ..orderBy([(t) => OrderingTerm.desc(t.starred)]);
    return query.watch();
  }

  /// Watch songs ordered by play count descending.
  Stream<List<SongsTableData>> watchMostPlayedSongs({int limit = 5}) {
    final query = select(songsTable)
      ..where((t) => t.playCount.isBiggerThanValue(0))
      ..orderBy([(t) => OrderingTerm.desc(t.playCount)])
      ..limit(limit);
    return query.watch();
  }

  Future<List<ArtistsTableData>> getAllArtists() {
    return select(artistsTable).get();
  }

  Future<Set<String>> getArtistIds() async {
    final query = selectOnly(artistsTable)..addColumns([artistsTable.id]);
    final rows = await query.get();
    return rows
        .map((row) => row.read(artistsTable.id))
        .whereType<String>()
        .toSet();
  }

  Future<List<AlbumsTableData>> getAllAlbums() {
    return select(albumsTable).get();
  }

  /// Return a map of albumId → set of songIds for the given album IDs.
  Future<Map<String, Set<String>>> getSongIdsByAlbumIds(
    Iterable<String> albumIds,
  ) async {
    final ids = albumIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) return const {};
    final query = select(songsTable)..where((t) => t.albumId.isIn(ids));
    final rows = await query.get();
    final result = <String, Set<String>>{};
    for (final row in rows) {
      final albumId = row.albumId;
      if (albumId == null) continue;
      (result[albumId] ??= <String>{}).add(row.id);
    }
    return result;
  }

  Future<List<SongsTableData>> getSongsByIds(Iterable<String> songIds) async {
    final ids = songIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return const <SongsTableData>[];
    }

    final query = select(songsTable)..where((table) => table.id.isIn(idList));
    final rows = await query.get();
    final byId = <String, SongsTableData>{for (final row in rows) row.id: row};
    final ordered = <SongsTableData>[];
    for (final id in idList) {
      final song = byId[id];
      if (song != null) {
        ordered.add(song);
      }
    }
    return ordered;
  }

  Future<Map<String, int?>> getAlbumSongCountsByIds(
    Iterable<String> albumIds,
  ) async {
    final ids = albumIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return const <String, int?>{};
    }

    final query = select(albumsTable)..where((table) => table.id.isIn(idList));
    final rows = await query.get();
    return <String, int?>{for (final row in rows) row.id: row.songCount};
  }

  Future<List<AlbumsTableData>> getAlbumsByArtist(String artistId) {
    final query = select(albumsTable)
      ..where((table) => table.artistId.equals(artistId));
    return query.get();
  }

  Future<void> deleteAlbumsByIds(Iterable<String> albumIds) async {
    final ids = albumIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return;
    }
    await transaction(() async {
      await (delete(
        songsTable,
      )..where((table) => table.albumId.isIn(ids))).go();
      await (delete(albumsTable)..where((table) => table.id.isIn(ids))).go();
    });
  }

  Future<void> removeArtistTree(String artistId) async {
    await transaction(() async {
      await (delete(
        songsTable,
      )..where((table) => table.artistId.equals(artistId))).go();
      await (delete(
        albumsTable,
      )..where((table) => table.artistId.equals(artistId))).go();
      await (delete(
        artistsTable,
      )..where((table) => table.id.equals(artistId))).go();
    });
  }

  Future<void> clearLibraryData() async {
    await transaction(() async {
      await delete(songsTable).go();
      await delete(albumsTable).go();
      await delete(artistsTable).go();
      await delete(genresTable).go();
    });
  }

  Future<List<AlbumsTableData>> getPendingHydrationAlbums({
    required int limit,
  }) {
    final query = _orderedAlbumsQuery(AlbumSortOrder.newest)
      ..where((table) => table.songsHydrated.equals(false))
      ..limit(limit < 1 ? 1 : limit);
    return query.get();
  }

  Future<List<String>> getPendingHydrationAlbumIds() async {
    final query = selectOnly(albumsTable)
      ..addColumns([albumsTable.id])
      ..where(albumsTable.songsHydrated.equals(false));
    final rows = await query.get();
    return rows
        .map((row) => row.read(albumsTable.id))
        .whereType<String>()
        .toList(growable: false);
  }

  Future<List<AlbumsTableData>> getPendingHydrationAlbumsByIds(
    Iterable<String> albumIds, {
    required int limit,
  }) async {
    final ids = albumIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return const <AlbumsTableData>[];
    }

    final query = select(albumsTable)
      ..where(
        (table) => table.songsHydrated.equals(false) & table.id.isIn(idList),
      )
      ..limit(limit < 1 ? 1 : limit);
    final rows = await query.get();
    final byId = <String, AlbumsTableData>{
      for (final row in rows) row.id: row,
    };
    final ordered = <AlbumsTableData>[];
    for (final id in idList) {
      final row = byId[id];
      if (row != null) {
        ordered.add(row);
      }
    }
    return ordered;
  }

  Future<int> countPendingHydrationAlbums() async {
    final countExpression = albumsTable.id.count();
    final query = selectOnly(albumsTable)
      ..addColumns([countExpression])
      ..where(albumsTable.songsHydrated.equals(false));
    final row = await query.getSingle();
    return row.read(countExpression) ?? 0;
  }

  Future<void> markAlbumsPendingHydrationByIds(
    Iterable<String> albumIds,
  ) async {
    final ids = albumIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return;
    }
    await (update(
      albumsTable,
    )..where((table) => table.id.isIn(ids))).write(
      const AlbumsTableCompanion(songsHydrated: Value(false)),
    );
  }

  Future<void> markAlbumSongsHydrated(String albumId) {
    return (update(
      albumsTable,
    )..where((table) => table.id.equals(albumId))).write(
      const AlbumsTableCompanion(songsHydrated: Value(true)),
    );
  }

  Future<void> markAlbumsSongsHydratedByIds(Iterable<String> albumIds) async {
    final ids = albumIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return;
    }
    await (update(
      albumsTable,
    )..where((table) => table.id.isIn(idList))).write(
      const AlbumsTableCompanion(songsHydrated: Value(true)),
    );
  }

  SimpleSelectStatement<$AlbumsTableTable, AlbumsTableData> _orderedAlbumsQuery(
    AlbumSortOrder sort,
  ) {
    final query = select(albumsTable);
    switch (sort) {
      case AlbumSortOrder.newest:
        query.orderBy([
          (table) => OrderingTerm.desc(table.year),
          (table) => OrderingTerm.asc(table.name),
          (table) => OrderingTerm.asc(table.id),
        ]);
      case AlbumSortOrder.name:
        query.orderBy([
          (table) => OrderingTerm.asc(table.name),
          (table) => OrderingTerm.asc(table.id),
        ]);
      case AlbumSortOrder.artist:
        query.orderBy([
          (table) => OrderingTerm.asc(table.artistName),
          (table) => OrderingTerm.asc(table.name),
          (table) => OrderingTerm.asc(table.id),
        ]);
    }
    return query;
  }
}
