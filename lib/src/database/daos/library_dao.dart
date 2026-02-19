import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'library_dao.g.dart';

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

  Stream<List<AlbumsTableData>> watchAllAlbums() {
    final query = select(albumsTable)
      ..orderBy([
        (table) => OrderingTerm.desc(table.year),
        (table) => OrderingTerm.asc(table.name),
      ]);
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

  Stream<List<SongsTableData>> watchAllSongs() {
    final query = select(songsTable)
      ..orderBy([
        (table) => OrderingTerm.asc(table.artistName),
        (table) => OrderingTerm.asc(table.albumName),
        (table) => OrderingTerm.asc(table.track),
      ]);
    return query.watch();
  }

  Stream<List<GenresTableData>> watchGenres() {
    final query = select(genresTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    return query.watch();
  }

  Future<void> replaceArtists(List<ArtistsTableCompanion> artists) async {
    await transaction(() async {
      await delete(artistsTable).go();
      await batch((batch) {
        batch.insertAll(artistsTable, artists);
      });
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

  Future<void> replaceSongs(List<SongsTableCompanion> songs) async {
    await transaction(() async {
      await delete(songsTable).go();
      await batch((batch) {
        batch.insertAll(songsTable, songs);
      });
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

  Future<void> clearLibraryData() async {
    await transaction(() async {
      await delete(songsTable).go();
      await delete(albumsTable).go();
      await delete(artistsTable).go();
      await delete(genresTable).go();
    });
  }
}
