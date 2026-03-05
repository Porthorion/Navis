import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/album_info_cache_table.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/external_lyrics_cache_table.dart';
import 'package:navis/src/database/tables/genres_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

part 'library_dao.g.dart';

enum AlbumSortOrder { recentlyAdded, newest, name, artist }

enum SongSortOrder { newest, oldest, name }

@DriftAccessor(
  tables: [
    ArtistsTable,
    AlbumsTable,
    SongsTable,
    GenresTable,
    AlbumInfoCacheTable,
    ExternalLyricsCacheTable,
  ],
)
class LibraryDao extends DatabaseAccessor<NavisDatabase>
    with _$LibraryDaoMixin {
  LibraryDao(super.db);

  Stream<List<ArtistsTableData>> watchArtists({bool likedOnly = false}) {
    final query = select(artistsTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    if (likedOnly) {
      query.where((table) => table.starred.isNotNull());
    }
    return query.watch();
  }

  Stream<List<ArtistsTableData>> watchLikedArtists() {
    // Recursive match: artist is liked, OR artist has a liked song,
    // OR artist has a liked album (album.starred IS NOT NULL).
    return customSelect(
      '''
      SELECT DISTINCT a.*
      FROM artists a
      WHERE a.starred IS NOT NULL
        OR EXISTS (
          SELECT 1 FROM songs s
          WHERE s.artist_id = a.id AND s.starred IS NOT NULL
        )
        OR EXISTS (
          SELECT 1 FROM albums al
          WHERE al.artist_id = a.id AND al.starred IS NOT NULL
        )
      ORDER BY a.name ASC
      ''',
      readsFrom: {artistsTable, songsTable, albumsTable},
    ).watch().map(
      (rows) => rows.map((row) => artistsTable.map(row.data)).toList(),
    );
  }

  Stream<List<AlbumsTableData>> watchAlbumsByArtist(String artistId) {
    return customSelect(
      '''
      SELECT al.*
      FROM albums al
      WHERE al.artist_id = ?1
         OR (
           (al.artist_id IS NULL OR al.artist_id = '')
           AND LOWER(COALESCE(al.artist_name, '')) = LOWER(
             COALESCE((SELECT name FROM artists WHERE id = ?1 LIMIT 1), '')
           )
         )
      ORDER BY al.year ASC, al.name ASC
      ''',
      variables: <Variable<Object>>[Variable<String>(artistId)],
      readsFrom: {albumsTable, artistsTable},
    ).watch().map(
      (rows) => rows.map((row) => albumsTable.map(row.data)).toList(),
    );
  }

  Stream<ArtistsTableData?> watchArtistById(String artistId) {
    final query = select(artistsTable)
      ..where((table) => table.id.equals(artistId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Stream<List<AlbumsTableData>> watchAllAlbums({bool likedOnly = false}) {
    if (!likedOnly) {
      final query = _orderedAlbumsQuery(AlbumSortOrder.newest);
      return query.watch();
    }
    return _watchAlbumsCustom(
      sort: AlbumSortOrder.newest,
      likedOnly: true,
    );
  }

  Stream<List<AlbumsTableData>> watchLikedAlbums() {
    return _watchAlbumsCustom(
      sort: AlbumSortOrder.newest,
      likedOnly: true,
    );
  }

  /// Returns the [limit] most recently liked albums, ordered by the album's
  /// own starred timestamp descending. Albums liked via a liked song (but not
  /// directly starred) are ordered last by name.
  Stream<List<AlbumsTableData>> watchRecentlyLikedAlbums({int limit = 6}) {
    return customSelect(
      '''
      SELECT albums.* FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
      ORDER BY
        albums.starred DESC NULLS LAST,
        albums.name ASC,
        albums.id ASC
      LIMIT ?
      ''',
      variables: [Variable<int>(limit < 1 ? 1 : limit)],
      readsFrom: {albumsTable, songsTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => albumsTable.map(row.data)).toList(growable: false),
    );
  }

  Stream<int> watchAlbumCount({bool likedOnly = false}) {
    if (!likedOnly) {
      final countExpression = albumsTable.id.count();
      final query = selectOnly(albumsTable)..addColumns([countExpression]);
      return query.watchSingle().map((row) => row.read(countExpression) ?? 0);
    }
    return customSelect(
      '''
      SELECT COUNT(*) AS count
      FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
      ''',
      readsFrom: {albumsTable, songsTable},
    ).watchSingle().map((row) => row.read<int>('count'));
  }

  Stream<List<AlbumsTableData>> watchAlbumsPage({
    required AlbumSortOrder sort,
    required int limit,
    int offset = 0,
    bool likedOnly = false,
  }) {
    if (!likedOnly) {
      final query = _orderedAlbumsQuery(sort)
        ..limit(
          limit < 1 ? 1 : limit,
          offset: offset < 0 ? 0 : offset,
        );
      return query.watch();
    }
    return _watchAlbumsCustom(
      sort: sort,
      limit: limit,
      offset: offset,
      likedOnly: true,
    );
  }

  Stream<List<AlbumsTableData>> watchAlbumsForYearView({
    bool likedOnly = false,
  }) {
    return _watchAlbumsCustom(
      sort: AlbumSortOrder.newest,
      likedOnly: likedOnly,
      includeUnknownYearsLast: true,
    );
  }

  Stream<List<AlbumsTableData>> watchAlbumsSorted({
    required AlbumSortOrder sort,
    bool likedOnly = false,
  }) {
    if (!likedOnly) {
      return _orderedAlbumsQuery(sort).watch();
    }
    return _watchAlbumsCustom(sort: sort, likedOnly: true);
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
    final now = DateTime.now();
    await transaction(() async {
      await delete(albumsTable).go();
      await batch((batch) {
        for (final album in albums) {
          batch.insert(albumsTable, album.copyWith(syncedAt: Value(now)));
        }
      });
    });
  }

  Future<void> upsertAlbums(List<AlbumsTableCompanion> albums) async {
    if (albums.isEmpty) {
      return;
    }
    final now = DateTime.now();
    await batch((batch) {
      for (final album in albums) {
        batch.insert(
          albumsTable,
          album.copyWith(syncedAt: Value(now)),
          onConflict: DoUpdate(
            (old) => album, // album.syncedAt is absent → preserves existing
            target: [albumsTable.id],
          ),
        );
      }
    });
    // Backfill syncedAt for albums that were migrated from schema < v16 and
    // therefore still have syncedAt = null even after the conflict-preserve
    // path above.  Only runs once per such row; subsequent upserts are no-ops.
    await (update(albumsTable)..where((t) => t.syncedAt.isNull())).write(
      AlbumsTableCompanion(syncedAt: Value(now)),
    );
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

  Future<void> updateSongRating(String songId, int? rating) {
    return (update(songsTable)..where((t) => t.id.equals(songId))).write(
      SongsTableCompanion(userRating: Value(rating)),
    );
  }

  Future<void> updateAlbumRating(String albumId, int? rating) {
    return (update(albumsTable)..where((t) => t.id.equals(albumId))).write(
      AlbumsTableCompanion(userRating: Value(rating)),
    );
  }

  Future<int?> getSongRating(String songId) async {
    final row = await (select(
      songsTable,
    )..where((t) => t.id.equals(songId))).getSingleOrNull();
    return row?.userRating;
  }

  Future<int?> getAlbumRating(String albumId) async {
    final row = await (select(
      albumsTable,
    )..where((t) => t.id.equals(albumId))).getSingleOrNull();
    return row?.userRating;
  }

  Stream<int?> watchSongRating(String songId) {
    final query = select(songsTable)..where((t) => t.id.equals(songId));
    return query.watchSingleOrNull().map((row) => row?.userRating);
  }

  Stream<int?> watchAlbumRating(String albumId) {
    final query = select(albumsTable)..where((t) => t.id.equals(albumId));
    return query.watchSingleOrNull().map((row) => row?.userRating);
  }

  Future<void> upsertAlbumInfoCache({
    required String albumId,
    String? notes,
    String? musicBrainzId,
    String? lastFmUrl,
    String? smallImageUrl,
    String? mediumImageUrl,
    String? largeImageUrl,
    DateTime? fetchedAt,
  }) {
    return into(albumInfoCacheTable).insertOnConflictUpdate(
      AlbumInfoCacheTableCompanion.insert(
        albumId: albumId,
        notes: Value(notes),
        musicBrainzId: Value(musicBrainzId),
        lastFmUrl: Value(lastFmUrl),
        smallImageUrl: Value(smallImageUrl),
        mediumImageUrl: Value(mediumImageUrl),
        largeImageUrl: Value(largeImageUrl),
        fetchedAt: fetchedAt ?? DateTime.now(),
      ),
    );
  }

  Future<AlbumInfoCacheTableData?> getAlbumInfoCache(String albumId) {
    return (select(
      albumInfoCacheTable,
    )..where((t) => t.albumId.equals(albumId))).getSingleOrNull();
  }

  Stream<AlbumInfoCacheTableData?> watchAlbumInfoCache(String albumId) {
    final query = select(
      albumInfoCacheTable,
    )..where((t) => t.albumId.equals(albumId));
    return query.watchSingleOrNull();
  }

  Future<ExternalLyricsCacheTableData?> getExternalLyricsCache(String songId) {
    return (select(
      externalLyricsCacheTable,
    )..where((t) => t.songId.equals(songId))).getSingleOrNull();
  }

  Future<void> upsertExternalLyricsCache({
    required String songId,
    required String source,
    String? syncedLyrics,
    String? plainLyrics,
    int ttlSeconds = 86400,
    int failureCount = 0,
    DateTime? lastFailedAt,
  }) {
    return into(externalLyricsCacheTable).insertOnConflictUpdate(
      ExternalLyricsCacheTableCompanion.insert(
        songId: songId,
        source: source,
        syncedLyrics: Value(syncedLyrics),
        plainLyrics: Value(plainLyrics),
        fetchedAt: DateTime.now(),
        ttlSeconds: Value(ttlSeconds),
        failureCount: Value(failureCount),
        lastFailedAt: Value(lastFailedAt),
      ),
    );
  }

  Future<void> recordExternalLyricsFailure(String songId) async {
    final existing = await getExternalLyricsCache(songId);
    final nextFailures = (existing?.failureCount ?? 0) + 1;
    await into(externalLyricsCacheTable).insertOnConflictUpdate(
      ExternalLyricsCacheTableCompanion.insert(
        songId: songId,
        source: existing?.source ?? 'none',
        syncedLyrics: Value(existing?.syncedLyrics),
        plainLyrics: Value(existing?.plainLyrics),
        fetchedAt: DateTime.now(),
        ttlSeconds: Value(existing?.ttlSeconds ?? 86400),
        failureCount: Value(nextFailures),
        lastFailedAt: Value(DateTime.now()),
      ),
    );
  }

  /// One-shot fetch of the current [starred] value for a single song.
  Future<DateTime?> getSongStarred(String songId) async {
    final row = await (select(
      songsTable,
    )..where((t) => t.id.equals(songId))).getSingleOrNull();
    return row?.starred;
  }

  /// Reactive stream emitting `true` when the song is starred.
  Stream<bool> watchSongStarred(String songId) {
    final query = select(songsTable)..where((t) => t.id.equals(songId));
    return query.watchSingleOrNull().map((row) => row?.starred != null);
  }

  /// Efficiently reconcile starred state for all albums in a single
  /// transaction.  Clears the [starred] column for albums not in
  /// [starredMap], and sets it for those that are — skipping IDs in
  /// [excludeIds] (e.g. items with pending offline star operations).
  Future<void> batchReconcileAlbumStarred(
    Map<String, DateTime?> starredMap, {
    Set<String> excludeIds = const <String>{},
  }) async {
    await transaction(() async {
      // 1. Clear starred for all non-excluded albums.
      if (excludeIds.isNotEmpty) {
        await (update(albumsTable)..where(
              (t) => t.starred.isNotNull() & t.id.isNotIn(excludeIds.toList()),
            ))
            .write(const AlbumsTableCompanion(starred: Value(null)));
      } else {
        await (update(albumsTable)..where(
              (t) => t.starred.isNotNull(),
            ))
            .write(const AlbumsTableCompanion(starred: Value(null)));
      }

      // 2. Set starred for each album in the server's starred set.
      for (final entry in starredMap.entries) {
        if (excludeIds.contains(entry.key)) continue;
        await (update(albumsTable)..where(
              (t) => t.id.equals(entry.key),
            ))
            .write(AlbumsTableCompanion(starred: Value(entry.value)));
      }
    });
  }

  /// Efficiently reconcile starred state for all artists in a single
  /// transaction.
  Future<void> batchReconcileArtistStarred(
    Map<String, DateTime?> starredMap, {
    Set<String> excludeIds = const <String>{},
  }) async {
    await transaction(() async {
      if (excludeIds.isNotEmpty) {
        await (update(artistsTable)..where(
              (t) => t.starred.isNotNull() & t.id.isNotIn(excludeIds.toList()),
            ))
            .write(const ArtistsTableCompanion(starred: Value(null)));
      } else {
        await (update(artistsTable)..where(
              (t) => t.starred.isNotNull(),
            ))
            .write(const ArtistsTableCompanion(starred: Value(null)));
      }

      for (final entry in starredMap.entries) {
        if (excludeIds.contains(entry.key)) continue;
        await (update(artistsTable)..where(
              (t) => t.id.equals(entry.key),
            ))
            .write(ArtistsTableCompanion(starred: Value(entry.value)));
      }
    });
  }

  /// Efficiently reconcile starred state for all songs in a single
  /// transaction.
  Future<void> batchReconcileSongStarred(
    Map<String, DateTime?> starredMap, {
    Set<String> excludeIds = const <String>{},
  }) async {
    await transaction(() async {
      if (excludeIds.isNotEmpty) {
        await (update(songsTable)..where(
              (t) => t.starred.isNotNull() & t.id.isNotIn(excludeIds.toList()),
            ))
            .write(const SongsTableCompanion(starred: Value(null)));
      } else {
        await (update(songsTable)..where(
              (t) => t.starred.isNotNull(),
            ))
            .write(const SongsTableCompanion(starred: Value(null)));
      }

      for (final entry in starredMap.entries) {
        if (excludeIds.contains(entry.key)) continue;
        await (update(songsTable)..where(
              (t) => t.id.equals(entry.key),
            ))
            .write(SongsTableCompanion(starred: Value(entry.value)));
      }
    });
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
  Stream<List<SongsTableData>> watchMostPlayedSongs({int? limit = 5}) {
    final query = select(songsTable)
      ..where((t) => t.playCount.isBiggerThanValue(0))
      ..orderBy([(t) => OrderingTerm.desc(t.playCount)]);
    if (limit != null) {
      query.limit(limit);
    }
    return query.watch();
  }

  Future<List<ArtistsTableData>> getAllArtists() {
    return select(artistsTable).get();
  }

  Future<int> countArtists() async {
    final countExpression = artistsTable.id.count();
    final query = selectOnly(artistsTable)..addColumns([countExpression]);
    final row = await query.getSingle();
    return row.read(countExpression) ?? 0;
  }

  Future<List<SongsTableData>> getAllSongs() {
    return select(songsTable).get();
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

  Future<List<AlbumsTableData>> getLikedAlbums() {
    return customSelect(
      '''
      SELECT albums.*
      FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
      ORDER BY albums.year DESC, albums.name ASC, albums.id ASC
      ''',
      readsFrom: {albumsTable, songsTable},
    ).get().then(
      (rows) =>
          rows.map((row) => albumsTable.map(row.data)).toList(growable: false),
    );
  }

  Future<List<SongsTableData>> getAllStarredSongs() {
    final query = select(songsTable)
      ..where((t) => t.starred.isNotNull())
      ..orderBy([(t) => OrderingTerm.desc(t.starred)]);
    return query.get();
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
    return customSelect(
      '''
      SELECT al.*
      FROM albums al
      WHERE al.artist_id = ?1
         OR (
           (al.artist_id IS NULL OR al.artist_id = '')
           AND LOWER(COALESCE(al.artist_name, '')) = LOWER(
             COALESCE((SELECT name FROM artists WHERE id = ?1 LIMIT 1), '')
           )
         )
      ORDER BY al.year ASC, al.name ASC
      ''',
      variables: <Variable<Object>>[Variable<String>(artistId)],
      readsFrom: {albumsTable, artistsTable},
    ).get().then(
      (rows) => rows.map((row) => albumsTable.map(row.data)).toList(),
    );
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

  // ── Local (offline) search ──────────────────────────────────────────────

  /// Search artists by name using case-insensitive LIKE matching.
  Future<List<ArtistsTableData>> searchArtistsLocal(
    String query, {
    int limit = 20,
  }) {
    final pattern = '%${query.toLowerCase()}%';
    return (select(artistsTable)
          ..where(
            (t) => t.name.lower().like(pattern),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.name)])
          ..limit(limit))
        .get();
  }

  /// Search albums by name or artist name.
  Future<List<AlbumsTableData>> searchAlbumsLocal(
    String query, {
    int limit = 20,
  }) {
    final pattern = '%${query.toLowerCase()}%';
    return (select(albumsTable)
          ..where(
            (t) =>
                t.name.lower().like(pattern) |
                t.artistName.lower().like(pattern),
          )
          ..orderBy([
            (t) => OrderingTerm.desc(t.year),
            (t) => OrderingTerm.asc(t.name),
          ])
          ..limit(limit))
        .get();
  }

  /// Search songs by title, artist name, or album name.
  Future<List<SongsTableData>> searchSongsLocal(
    String query, {
    int limit = 20,
  }) {
    final pattern = '%${query.toLowerCase()}%';
    return (select(songsTable)
          ..where(
            (t) =>
                t.title.lower().like(pattern) |
                t.artistName.lower().like(pattern) |
                t.albumName.lower().like(pattern),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.title),
            (t) => OrderingTerm.asc(t.id),
          ])
          ..limit(limit))
        .get();
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
      case AlbumSortOrder.recentlyAdded:
        // Sort by when the album was added to the server (serverCreatedAt),
        // falling back to our local sync timestamp so pre-v17 rows still sort.
        query.orderBy([
          (table) => OrderingTerm(
            expression: CustomExpression<DateTime>(
              'COALESCE(server_created_at, synced_at)',
            ),
            mode: OrderingMode.desc,
            nulls: NullsOrder.last,
          ),
          (table) => OrderingTerm.asc(table.name),
          (table) => OrderingTerm.asc(table.id),
        ]);
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

  Stream<List<AlbumsTableData>> _watchAlbumsCustom({
    required AlbumSortOrder sort,
    bool likedOnly = false,
    int? limit,
    int? offset,
    bool includeUnknownYearsLast = false,
  }) {
    final sql = StringBuffer('SELECT albums.* FROM albums');
    if (likedOnly) {
      sql.write(' WHERE ${_likedAlbumPredicate('albums')}');
    }
    sql.write(' ORDER BY ${_albumOrderSql(sort, includeUnknownYearsLast)}');
    final variables = <Variable<Object>>[];
    if (limit != null) {
      sql.write(' LIMIT ?');
      variables.add(Variable<int>(limit < 1 ? 1 : limit));
    }
    if (offset != null) {
      sql.write(' OFFSET ?');
      variables.add(Variable<int>(offset < 0 ? 0 : offset));
    }
    return customSelect(
      sql.toString(),
      variables: variables,
      readsFrom: {albumsTable, songsTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => albumsTable.map(row.data)).toList(growable: false),
    );
  }

  String _likedAlbumPredicate(String albumAlias) {
    // Only explicitly starred albums — liked songs have their own section.
    return '$albumAlias.starred IS NOT NULL';
  }

  String _albumOrderSql(AlbumSortOrder sort, bool includeUnknownYearsLast) {
    switch (sort) {
      case AlbumSortOrder.recentlyAdded:
        return 'COALESCE(server_created_at, synced_at) DESC, name ASC, id ASC';
      case AlbumSortOrder.newest:
        if (includeUnknownYearsLast) {
          return 'year IS NULL ASC, year DESC, name ASC, id ASC';
        }
        return 'year DESC, name ASC, id ASC';
      case AlbumSortOrder.name:
        return 'name ASC, id ASC';
      case AlbumSortOrder.artist:
        return 'artist_name ASC, name ASC, id ASC';
    }
  }
}
