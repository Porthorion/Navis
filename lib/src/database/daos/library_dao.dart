import 'dart:async';

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

class ArtistAlbumBuckets {
  const ArtistAlbumBuckets({
    this.primaryAlbums = const <AlbumsTableData>[],
    this.featuredInAlbums = const <AlbumsTableData>[],
  });

  final List<AlbumsTableData> primaryAlbums;
  final List<AlbumsTableData> featuredInAlbums;

  bool get isEmpty => primaryAlbums.isEmpty && featuredInAlbums.isEmpty;
}

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
    // Order by the latest liked timestamp across those sources.
    return customSelect(
      '''
      SELECT DISTINCT a.*
      FROM artists a
      LEFT JOIN (
        SELECT s.artist_id, MAX(s.starred) AS song_starred
        FROM songs s
        WHERE s.starred IS NOT NULL
        GROUP BY s.artist_id
      ) song_likes ON song_likes.artist_id = a.id
      LEFT JOIN (
        SELECT al.artist_id, MAX(al.starred) AS album_starred
        FROM albums al
        WHERE al.starred IS NOT NULL
        GROUP BY al.artist_id
      ) album_likes ON album_likes.artist_id = a.id
      WHERE a.starred IS NOT NULL
        OR song_likes.song_starred IS NOT NULL
        OR album_likes.album_starred IS NOT NULL
      ORDER BY MAX(
        IFNULL(a.starred, 0),
        IFNULL(song_likes.song_starred, 0),
        IFNULL(album_likes.album_starred, 0)
      ) DESC,
      LOWER(a.name) ASC
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
      ORDER BY
        al.year IS NULL ASC,
        al.year DESC,
        al.server_created_at IS NULL ASC,
        al.server_created_at DESC,
        al.name ASC,
        al.id ASC
      ''',
      variables: <Variable<Object>>[Variable<String>(artistId)],
      readsFrom: {albumsTable, artistsTable},
    ).watch().map(
      (rows) => rows.map((row) => albumsTable.map(row.data)).toList(),
    );
  }

  Stream<ArtistAlbumBuckets> watchArtistAlbumBuckets(String artistId) {
    final id = artistId.trim();
    if (id.isEmpty) {
      return Stream<ArtistAlbumBuckets>.value(const ArtistAlbumBuckets());
    }

    final controller = StreamController<ArtistAlbumBuckets>();
    ArtistsTableData? currentArtist;
    List<AlbumsTableData> currentAlbums = const <AlbumsTableData>[];
    Set<String> currentSongAlbumIds = const <String>{};

    void emitBuckets() {
      controller.add(
        _buildArtistAlbumBuckets(
          albums: currentAlbums,
          artistId: id,
          artistName: currentArtist?.name,
          relatedSongAlbumIds: currentSongAlbumIds,
        ),
      );
    }

    final artistSub = watchArtistById(id).listen(
      (artist) {
        currentArtist = artist;
        emitBuckets();
      },
      onError: controller.addError,
    );

    final albumsSub = select(albumsTable).watch().listen(
      (albums) {
        currentAlbums = albums;
        emitBuckets();
      },
      onError: controller.addError,
    );

    final songsSub = watchSongsByArtist(id).listen(
      (songs) {
        currentSongAlbumIds = songs
            .map((song) => song.albumId?.trim() ?? '')
            .where((albumId) => albumId.isNotEmpty)
            .toSet();
        emitBuckets();
      },
      onError: controller.addError,
    );

    controller.onCancel = () async {
      await artistSub.cancel();
      await albumsSub.cancel();
      await songsSub.cancel();
    };

    return controller.stream;
  }

  Stream<ArtistsTableData?> watchArtistById(String artistId) {
    final query = select(artistsTable)
      ..where((table) => table.id.equals(artistId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Future<ArtistsTableData?> getArtistById(String artistId) {
    final id = artistId.trim();
    if (id.isEmpty) {
      return Future<ArtistsTableData?>.value();
    }
    final query = select(artistsTable)
      ..where((table) => table.id.equals(id))
      ..limit(1);
    return query.getSingleOrNull();
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

  Future<AlbumsTableData?> getAlbumById(String albumId) {
    final id = albumId.trim();
    if (id.isEmpty) {
      return Future<AlbumsTableData?>.value();
    }
    final query = select(albumsTable)
      ..where((table) => table.id.equals(id))
      ..limit(1);
    return query.getSingleOrNull();
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

  Stream<List<SongsTableData>> watchSongsByArtist(String artistId) {
    return customSelect(
      '''
      SELECT s.*
      FROM songs s
      LEFT JOIN albums al ON al.id = s.album_id
      WHERE s.artist_id = ?1
      ORDER BY
        al.year IS NULL ASC,
        al.year ASC,
        s.album_name IS NULL ASC,
        s.album_name ASC,
        s.track IS NULL ASC,
        s.track ASC
      ''',
      variables: <Variable<Object>>[Variable<String>(artistId)],
      readsFrom: {songsTable, albumsTable},
    ).watch().map(
      (rows) => rows.map((row) => songsTable.map(row.data)).toList(),
    );
  }

  Stream<SongsTableData?> watchSongById(String songId) {
    final query = select(songsTable)
      ..where((table) => table.id.equals(songId))
      ..limit(1);
    return query.watchSingleOrNull();
  }

  Future<SongsTableData?> getSongById(String songId) {
    final id = songId.trim();
    if (id.isEmpty) {
      return Future<SongsTableData?>.value();
    }
    final query = select(songsTable)
      ..where((table) => table.id.equals(id))
      ..limit(1);
    return query.getSingleOrNull();
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

  Future<ArtistsTableData?> findOneExactNormalizedArtistByName(
    String name,
  ) async {
    final normalizedName = _normalizeMetadataLookup(name);
    if (normalizedName.isEmpty) {
      return null;
    }

    final matches = (await getAllArtists())
        .where(
          (artist) => _normalizeMetadataLookup(artist.name) == normalizedName,
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
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

  Future<AlbumsTableData?> findOneExactNormalizedAlbumByName(
    String albumName, {
    String? artistId,
    String? artistName,
  }) async {
    final normalizedAlbum = _normalizeMetadataLookup(albumName);
    if (normalizedAlbum.isEmpty) {
      return null;
    }

    final exactAlbums = (await getAllAlbums())
        .where(
          (album) => _normalizeMetadataLookup(album.name) == normalizedAlbum,
        )
        .toList(growable: false);
    if (exactAlbums.isEmpty) {
      return null;
    }

    final id = artistId?.trim();
    final normalizedArtist = _normalizeMetadataLookup(artistName ?? '');
    if ((id != null && id.isNotEmpty) || normalizedArtist.isNotEmpty) {
      final contextMatches = exactAlbums
          .where((album) {
            if (id != null && id.isNotEmpty) {
              if (album.artistId == id) {
                return true;
              }
              if (album.artists.any((artist) => artist.id == id)) {
                return true;
              }
            }
            if (normalizedArtist.isNotEmpty) {
              if (_normalizeMetadataLookup(album.artistName ?? '') ==
                  normalizedArtist) {
                return true;
              }
              if (album.artists.any(
                (artist) =>
                    _normalizeMetadataLookup(artist.name) == normalizedArtist,
              )) {
                return true;
              }
            }
            return false;
          })
          .toList(growable: false);
      if (contextMatches.isNotEmpty) {
        return contextMatches.length == 1 ? contextMatches.single : null;
      }
    }

    return exactAlbums.length == 1 ? exactAlbums.single : null;
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

  Future<SongsTableData?> findOneExactNormalizedSongByTitle(
    String title, {
    String? artistId,
    String? artistName,
    String? albumId,
    String? albumName,
  }) async {
    final normalizedTitle = _normalizeMetadataLookup(title);
    if (normalizedTitle.isEmpty) {
      return null;
    }

    final exactSongs = (await getAllSongs())
        .where(
          (song) => _normalizeMetadataLookup(song.title) == normalizedTitle,
        )
        .toList(growable: false);
    if (exactSongs.isEmpty) {
      return null;
    }

    final normalizedAlbum = _normalizeMetadataLookup(albumName ?? '');
    final normalizedArtist = _normalizeMetadataLookup(artistName ?? '');
    final trimmedAlbumId = albumId?.trim();
    final trimmedArtistId = artistId?.trim();
    final filters = <bool Function(SongsTableData)>[
      if (trimmedAlbumId != null && trimmedAlbumId.isNotEmpty)
        (song) => song.albumId == trimmedAlbumId,
      if (normalizedAlbum.isNotEmpty &&
          trimmedArtistId != null &&
          trimmedArtistId.isNotEmpty)
        (song) =>
            _normalizeMetadataLookup(song.albumName ?? '') == normalizedAlbum &&
            song.artistId == trimmedArtistId,
      if (normalizedAlbum.isNotEmpty && normalizedArtist.isNotEmpty)
        (song) =>
            _normalizeMetadataLookup(song.albumName ?? '') == normalizedAlbum &&
            _normalizeMetadataLookup(song.artistName ?? '') == normalizedArtist,
      if (normalizedAlbum.isNotEmpty)
        (song) =>
            _normalizeMetadataLookup(song.albumName ?? '') == normalizedAlbum,
      if (trimmedArtistId != null && trimmedArtistId.isNotEmpty)
        (song) => song.artistId == trimmedArtistId,
      if (normalizedArtist.isNotEmpty)
        (song) =>
            _normalizeMetadataLookup(song.artistName ?? '') == normalizedArtist,
    ];

    for (final filter in filters) {
      final matches = exactSongs.where(filter).toList(growable: false);
      if (matches.isEmpty) {
        continue;
      }
      return matches.length == 1 ? matches.single : null;
    }

    return exactSongs.length == 1 ? exactSongs.single : null;
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
      ORDER BY
        al.year IS NULL ASC,
        al.year DESC,
        al.server_created_at IS NULL ASC,
        al.server_created_at DESC,
        al.name ASC,
        al.id ASC
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

  /// Search songs by title, artist name, or album name using cached metadata.
  Future<List<SongsTableData>> searchSongsLocal(
    String query, {
    int limit = 20,
  }) {
    return searchCachedSongs(query, limit: limit);
  }

  /// Search cached songs with ranked substring, token, and fuzzy matching.
  Future<List<SongsTableData>> searchCachedSongs(
    String query, {
    int limit = 20,
  }) async {
    if (limit < 1) return const <SongsTableData>[];
    final normalizedQuery = _normalizeSearchText(query);
    if (normalizedQuery.isEmpty) {
      return (select(songsTable)
            ..orderBy([
              (t) => OrderingTerm.asc(t.title),
              (t) => OrderingTerm.asc(t.id),
            ])
            ..limit(limit))
          .get();
    }

    final songs =
        await (select(songsTable)..orderBy([
              (t) => OrderingTerm.asc(t.title),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    final tokens = normalizedQuery
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final matches = <_SongSearchMatch>[];

    for (final song in songs) {
      final score = _songSearchScore(song, normalizedQuery, tokens);
      if (score == null) continue;
      matches.add(_SongSearchMatch(song: song, score: score));
    }

    matches.sort((a, b) {
      final scoreDiff = a.score.compareTo(b.score);
      if (scoreDiff != 0) return scoreDiff;
      final titleDiff = a.song.title.toLowerCase().compareTo(
        b.song.title.toLowerCase(),
      );
      if (titleDiff != 0) return titleDiff;
      return a.song.id.compareTo(b.song.id);
    });

    return matches
        .take(limit)
        .map((match) => match.song)
        .toList(growable: false);
  }

  int? _songSearchScore(
    SongsTableData song,
    String query,
    List<String> tokens,
  ) {
    final scores = <int>[];
    final title = _normalizeSearchText(song.title);
    final artist = _normalizeSearchText(song.artistName ?? '');
    final album = _normalizeSearchText(song.albumName ?? '');
    final combined = <String>[
      title,
      artist,
      album,
    ].where((field) => field.isNotEmpty).join(' ');

    void addScore(String field, int weight) {
      final score = _searchFieldScore(field, query, tokens);
      if (score != null) scores.add(weight + score);
    }

    addScore(title, 0);
    addScore(artist, 8);
    addScore(album, 12);
    addScore(combined, 18);

    if (scores.isEmpty) return null;
    scores.sort();
    return scores.first;
  }

  int? _searchFieldScore(String field, String query, List<String> tokens) {
    if (field.isEmpty) return null;
    if (field == query) return 0;
    if (field.startsWith(query)) return 10;

    final containsIndex = field.indexOf(query);
    if (containsIndex >= 0) return 20 + containsIndex.clamp(0, 20);

    if (tokens.length > 1 && tokens.every(field.contains)) {
      final firstIndex = field.indexOf(tokens.first).clamp(0, 30);
      return 45 + firstIndex;
    }

    final fuzzyScore = _fuzzySubsequenceScore(field, query);
    if (fuzzyScore != null) return 80 + fuzzyScore;

    if (tokens.length > 1) {
      var total = 0;
      for (final token in tokens) {
        final tokenScore = _fuzzySubsequenceScore(field, token);
        if (tokenScore == null) return null;
        total += tokenScore;
      }
      return 110 + total;
    }

    return null;
  }

  int? _fuzzySubsequenceScore(String field, String query) {
    if (query.length < 3 || field.length < query.length) return null;
    var fieldIndex = 0;
    var previousMatch = -1;
    var gapPenalty = 0;

    for (var queryIndex = 0; queryIndex < query.length; queryIndex += 1) {
      final char = query[queryIndex];
      final matchIndex = field.indexOf(char, fieldIndex);
      if (matchIndex < 0) return null;
      if (previousMatch >= 0) {
        gapPenalty += matchIndex - previousMatch - 1;
      } else {
        gapPenalty += matchIndex.clamp(0, 20);
      }
      previousMatch = matchIndex;
      fieldIndex = matchIndex + 1;
    }

    final compactnessLimit = query.length * 3;
    if (gapPenalty > compactnessLimit) return null;
    return gapPenalty;
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
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

  ArtistAlbumBuckets _buildArtistAlbumBuckets({
    required Iterable<AlbumsTableData> albums,
    required String artistId,
    required String? artistName,
    required Set<String> relatedSongAlbumIds,
  }) {
    final primaryAlbumsById = <String, AlbumsTableData>{};
    final featuredAlbumsById = <String, AlbumsTableData>{};
    final normalizedArtistName = _normalizeMetadataLookup(artistName ?? '');

    for (final album in albums) {
      final isPrimary = _isPrimaryArtistAlbum(
        album,
        artistId: artistId,
        normalizedArtistName: normalizedArtistName,
      );
      final isFeatured =
          !isPrimary &&
          (_albumHasFeaturedArtistCredit(
                album,
                artistId: artistId,
                normalizedArtistName: normalizedArtistName,
              ) ||
              relatedSongAlbumIds.contains(album.id));

      if (isPrimary) {
        primaryAlbumsById.putIfAbsent(album.id, () => album);
        continue;
      }
      if (isFeatured) {
        featuredAlbumsById.putIfAbsent(album.id, () => album);
      }
    }

    final primaryAlbums = primaryAlbumsById.values.toList(growable: false)
      ..sort(_compareArtistAlbums);
    final featuredInAlbums =
        featuredAlbumsById.values
            .where((album) => !primaryAlbumsById.containsKey(album.id))
            .toList(growable: false)
          ..sort(_compareArtistAlbums);

    return ArtistAlbumBuckets(
      primaryAlbums: primaryAlbums,
      featuredInAlbums: featuredInAlbums,
    );
  }

  bool _isPrimaryArtistAlbum(
    AlbumsTableData album, {
    required String artistId,
    required String normalizedArtistName,
  }) {
    final albumArtistId = album.artistId?.trim() ?? '';
    if (albumArtistId.isNotEmpty && albumArtistId == artistId) {
      return true;
    }

    if (albumArtistId.isEmpty && normalizedArtistName.isNotEmpty) {
      return _normalizeMetadataLookup(album.artistName ?? '') ==
          normalizedArtistName;
    }

    return false;
  }

  bool _albumHasFeaturedArtistCredit(
    AlbumsTableData album, {
    required String artistId,
    required String normalizedArtistName,
  }) {
    for (final artist in album.artists) {
      if (artist.id.trim() == artistId) {
        return true;
      }
      if (normalizedArtistName.isNotEmpty &&
          _normalizeMetadataLookup(artist.name) == normalizedArtistName) {
        return true;
      }
    }
    return false;
  }

  int _compareArtistAlbums(AlbumsTableData a, AlbumsTableData b) {
    final yearCompare = _compareNullableIntDesc(a.year, b.year);
    if (yearCompare != 0) {
      return yearCompare;
    }

    final createdCompare = _compareNullableDateTimeDesc(
      a.serverCreatedAt,
      b.serverCreatedAt,
    );
    if (createdCompare != 0) {
      return createdCompare;
    }

    final nameCompare = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (nameCompare != 0) {
      return nameCompare;
    }

    return a.id.compareTo(b.id);
  }

  int _compareNullableIntDesc(int? a, int? b) {
    if (a == null && b == null) {
      return 0;
    }
    if (a == null) {
      return 1;
    }
    if (b == null) {
      return -1;
    }
    return b.compareTo(a);
  }

  int _compareNullableDateTimeDesc(DateTime? a, DateTime? b) {
    if (a == null && b == null) {
      return 0;
    }
    if (a == null) {
      return 1;
    }
    if (b == null) {
      return -1;
    }
    return b.compareTo(a);
  }

  String _normalizeMetadataLookup(String value) {
    final lower = value.toLowerCase().trim();
    final withoutParen = lower.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    final withoutFeat = withoutParen.replaceAll(
      RegExp(r'\b(feat\.?|ft\.?)\b.*$'),
      ' ',
    );
    final withoutPunct = withoutFeat.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return withoutPunct.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class _SongSearchMatch {
  const _SongSearchMatch({required this.song, required this.score});

  final SongsTableData song;
  final int score;
}
