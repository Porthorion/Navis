import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/search_text.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/database_utils.dart';
import 'package:navis/src/database/snapshot_write_guard.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/database/tables/album_info_cache_table.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/artists_table.dart';
import 'package:navis/src/database/tables/cached_tracks_table.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/external_lyrics_cache_table.dart';
import 'package:navis/src/database/tables/listenbrainz_feedback_queue_table.dart';
import 'package:navis/src/database/tables/library_sync_local_mutations_table.dart';
import 'package:navis/src/database/tables/match_flow_songs_table.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/play_queue_items_table.dart';
import 'package:navis/src/database/tables/playlist_songs_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/scrobble_queue_table.dart';
import 'package:navis/src/database/tables/song_search_text_table.dart';
import 'package:navis/src/database/tables/album_artist_index_table.dart';
import 'package:navis/src/database/tables/artist_ref_converter.dart';
import 'package:navis/src/utils/metadata_normalization.dart';
import 'package:navis/src/features/library/data/library_artist_name_index.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart'
    show kLocalTrackMatcherSnapshotYieldChunkSize;
import 'package:rxdart/rxdart.dart';
import 'package:navis/src/database/tables/songs_table.dart';
import 'package:navis/src/features/downloads/data/android_saf_storage.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';
import 'package:navis/src/utils/file_utils.dart';

part 'library_dao.g.dart';

enum AlbumSortOrder { recentlyAdded, newest, name, artist }

enum SongSortOrder { newest, oldest, name }

class ArtistAlbumBuckets {
  const new({
    this.primaryAlbums = const <AlbumsTableData>[],
    this.featuredInAlbums = const <AlbumsTableData>[],
  });

  final List<AlbumsTableData> primaryAlbums;
  final List<AlbumsTableData> featuredInAlbums;

  bool get isEmpty => primaryAlbums.isEmpty && featuredInAlbums.isEmpty;
}

/// A consistent release and track snapshot for an artist playback action.
class ArtistPlaybackSnapshot {
  const new({required this.artist, required this.albums, required this.songs});

  final ArtistsTableData? artist;
  final List<AlbumsTableData> albums;
  final List<SongsTableData> songs;

  /// This snapshot with one album's row and songs refreshed, keeping album
  /// order. Lets artist playback publish a newly hydrated release without
  /// re-reading the whole catalogue.
  ArtistPlaybackSnapshot withAlbum(
    String albumId,
    AlbumsTableData? album,
    List<SongsTableData> albumSongs,
  ) {
    final albumIndex = albums.indexWhere((entry) => entry.id == albumId);
    if (albumIndex < 0) return this;
    final nextAlbums = List<AlbumsTableData>.of(albums);
    if (album != null) nextAlbums[albumIndex] = album;
    final ranks = <String, int>{
      for (var i = 0; i < nextAlbums.length; i++) nextAlbums[i].id: i,
    };
    final kept = songs.where((song) => song.albumId != albumId).toList();
    var insertAt = kept.length;
    for (var i = 0; i < kept.length; i++) {
      final rank = ranks[kept[i].albumId];
      if (rank == null || rank > albumIndex) {
        insertAt = i;
        break;
      }
    }
    final seen = kept.map((song) => song.id).toSet();
    kept.insertAll(insertAt, albumSongs.where((song) => seen.add(song.id)));
    return ArtistPlaybackSnapshot(
      artist: artist,
      albums: List<AlbumsTableData>.unmodifiable(nextAlbums),
      songs: List<SongsTableData>.unmodifiable(kept),
    );
  }
}

class PreservedProvisionalTree {
  const new({
    this.artistIds = const <String>{},
    this.albumIds = const <String>{},
    this.songIds = const <String>{},
  });

  final Set<String> artistIds;
  final Set<String> albumIds;
  final Set<String> songIds;
}

/// Outcome of applying a validated server absence to local song rows.
class RetainedServerSongsResult {
  const new({
    this.deferredCacheFiles = const <String>[],
    this.retainedUnavailableIds = const <String>[],
  });

  final List<String> deferredCacheFiles;

  /// Rows kept because they own user state or references; candidates for
  /// recovery review rather than silent deletion.
  final List<String> retainedUnavailableIds;
}

class LibraryCatalogCounts {
  const new({required this.artists, required this.albums, required this.songs});

  final int artists;
  final int albums;
  final int songs;
}

/// Minimal metadata used while reconciling a user-owned download folder.
///
/// Keeping this separate from [SongsTableData] prevents a folder scan from
/// hydrating every column of a large library just to compare file names.
class DownloadReconciliationSong {
  const new({
    required this.id,
    required this.title,
    required this.artistName,
    required this.suffix,
  });

  final String id;
  final String title;
  final String? artistName;
  final String? suffix;
}

@DriftAccessor(
  tables: [
    ArtistsTable,
    AlbumsTable,
    SongsTable,
    SongSearchTextTable,
    AlbumArtistIndexTable,
    AlbumInfoCacheTable,
    ExternalLyricsCacheTable,
    CachedTracksTable,
    DownloadQueueTable,
    MatchFlowSongsTable,
    LibrarySyncLocalMutationsTable,
    StarSyncQueueTable,
    PlayHistoryTable,
    PlayQueueItemsTable,
    PlaylistSongsTable,
    ScrobbleQueueTable,
    ListenBrainzFeedbackQueueTable,
  ],
)
class LibraryDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$LibraryDaoMixin {
  new(super.attachedDatabase);

  /// Shared name index for metadata navigation and related-artist links.
  late final LibraryArtistNameIndexCache artistNameIndex = _artistNameIndex();

  LibraryArtistNameIndexCache _artistNameIndex() {
    final cache = LibraryArtistNameIndexCache(loadArtists: getAllArtists);
    // The database owns this stream and closes it with its query executor.
    tableUpdates(TableUpdateQuery.onTable(artistsTable))
        .listen((_) => cache.markStale());
    return cache;
  }

  static const _safeSqlVariableChunkSize = 500;

  Stream<List<ArtistsTableData>> watchArtists({bool likedOnly = false}) {
    final query = select(artistsTable)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    if (likedOnly) {
      query.where((table) => table.starred.isNotNull());
    } else {
      query.where((table) => table.isProvisional.equals(false));
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
      WHERE (
          a.starred IS NOT NULL
          OR song_likes.song_starred IS NOT NULL
          OR album_likes.album_starred IS NOT NULL
        )
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
      WHERE (al.is_provisional = 0 OR al.is_external = 1)
        AND (
          al.artist_id = ?1
          OR (
            (al.artist_id IS NULL OR al.artist_id = '')
            AND LOWER(COALESCE(al.artist_name, '')) = LOWER(
              COALESCE((SELECT name FROM artists WHERE id = ?1 LIMIT 1), '')
            )
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

  Future<ArtistPlaybackSnapshot> getArtistPlaybackSnapshot(
    String artistId,
  ) async {
    // Repair the derived artist index before the read transaction, which
    // must not hold the writer while keys are computed.
    await refreshAlbumArtistIndex();
    return transaction(() async {
      final artist = await getArtistById(artistId);
      final directSongs =
          await (select(songsTable)..where(
                (table) =>
                    table.artistId.equals(artistId) &
                    (table.isProvisional.equals(false) |
                        table.isExternal.equals(true)) &
                    _selectableForBulkUse,
              ))
              .get();
      final relatedAlbumIds = directSongs
          .map((song) => song.albumId)
          .nonNulls
          .toSet();
      final visibleAlbums = await _artistAlbumCandidates(
        artistId: artistId,
        artistName: artist?.name,
        relatedAlbumIds: relatedAlbumIds,
        // Refreshed just before the transaction. Refreshing inside it could
        // join a single-flight refresh started outside, which waits for this
        // transaction to release the database: a deadlock.
        refreshIndex: false,
      );
      final buckets = _buildArtistAlbumBuckets(
        albums: visibleAlbums,
        artistId: artistId,
        artistName: artist?.name,
        relatedSongAlbumIds: relatedAlbumIds,
      );
      final albums = [...buckets.primaryAlbums, ...buckets.featuredInAlbums]
        ..sort((a, b) {
          final aYear = a.year != null && a.year! > 0 ? a.year! : 0x7fffffff;
          final bYear = b.year != null && b.year! > 0 ? b.year! : 0x7fffffff;
          final year = aYear.compareTo(bYear);
          if (year != 0) return year;
          final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return name != 0 ? name : a.id.compareTo(b.id);
        });
      final albumIds = albums.map((album) => album.id).toSet();
      final albumIdList = albumIds.toList(growable: false);
      final albumSongs = <SongsTableData>[];
      for (final chunk in chunked(albumIdList, _safeSqlVariableChunkSize)) {
        albumSongs.addAll(
          await (select(songsTable)..where(
                (table) =>
                    table.albumId.isIn(chunk) &
                    (table.isProvisional.equals(false) |
                        table.isExternal.equals(true)) &
                    _selectableForBulkUse,
              ))
              .get(),
        );
      }
      final ranks = {for (var i = 0; i < albums.length; i++) albums[i].id: i};
      albumSongs.sort((a, b) {
        final album = ranks[a.albumId]!.compareTo(ranks[b.albumId]!);
        if (album != 0) return album;
        final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
        if (disc != 0) return disc;
        final track = (a.track ?? 0x7fffffff).compareTo(b.track ?? 0x7fffffff);
        return track != 0 ? track : a.id.compareTo(b.id);
      });
      final looseSongs =
          directSongs.where((song) => !albumIds.contains(song.albumId)).toList()
            ..sort((a, b) {
              final title = a.title.toLowerCase().compareTo(
                b.title.toLowerCase(),
              );
              return title != 0 ? title : a.id.compareTo(b.id);
            });
      final seen = <String>{};
      return ArtistPlaybackSnapshot(
        artist: artist,
        albums: albums,
        songs: [
          ...albumSongs,
          ...looseSongs,
        ].where((song) => seen.add(song.id)).toList(growable: false),
      );
    });
  }

  /// One album's row and playable songs, filtered and ordered like
  /// [getArtistPlaybackSnapshot].
  Future<({AlbumsTableData? album, List<SongsTableData> songs})>
  getArtistPlaybackAlbum(String albumId) async {
    final album = await (select(
      albumsTable,
    )..where((table) => table.id.equals(albumId))).getSingleOrNull();
    final songs =
        await (select(songsTable)..where(
              (table) =>
                  table.albumId.equals(albumId) &
                  (table.isProvisional.equals(false) |
                      table.isExternal.equals(true)) &
                  _selectableForBulkUse,
            ))
            .get();
    songs.sort((a, b) {
      final disc = (a.discNumber ?? 1).compareTo(b.discNumber ?? 1);
      if (disc != 0) return disc;
      final track = (a.track ?? 0x7fffffff).compareTo(b.track ?? 0x7fffffff);
      return track != 0 ? track : a.id.compareTo(b.id);
    });
    return (album: album, songs: songs);
  }

  Future<int>? _albumArtistIndexRefresh;

  // The trailing key version makes rows keyed by an older normalizer stale.
  static const String _albumArtistSourceSql =
      "ifnull(a.artist_id, '') || char(31) || ifnull(a.artist_name, '') "
      "|| char(31) || a.artists || char(31) || '$metadataKeyVersion'";

  /// Writes every missing or stale `album_artist_index` row. Single-flight;
  /// concurrent callers share one refresh. Returns the rows written.
  ///
  /// A failure is logged and reported as 0 rows: artist pages then read the
  /// index as it is, and the next call retries.
  Future<int> refreshAlbumArtistIndex() {
    return _albumArtistIndexRefresh ??= _refreshAlbumArtistIndex()
        .catchError((Object error, StackTrace stackTrace) {
          AppLogger.warning(
            'Album artist index refresh failed '
            '(${error.runtimeType}): $error\n$stackTrace',
          );
          return 0;
        })
        .whenComplete(() => _albumArtistIndexRefresh = null);
  }

  Future<int> _refreshAlbumArtistIndex({int batchSize = 1000}) async {
    var written = 0;
    final writtenIds = <String>{};
    while (true) {
      final rows = await customSelect(
        '''
        SELECT a.id AS id, a.artist_id AS artist_id,
          a.artist_name AS artist_name, a.artists AS artists
        FROM albums a
        LEFT JOIN album_artist_index x ON x.album_id = a.id
        WHERE x.source IS NOT ($_albumArtistSourceSql)
        LIMIT ?
        ''',
        variables: <Variable<Object>>[Variable<int>(batchSize)],
        readsFrom: {albumsTable, albumArtistIndexTable},
      ).get();
      if (rows.isEmpty) break;
      // Rows written in this refresh that are selected again would be
      // rewritten forever: their stored source never matches the query's.
      if (rows.every((row) => writtenIds.contains(row.read<String>('id')))) {
        AppLogger.warning(
          'Album artist index refresh made no progress on ${rows.length} '
          'albums; stopping.',
        );
        break;
      }
      final raw = <(String, String?, String?, String)>[
        for (final row in rows)
          (
            row.read<String>('id'),
            row.readNullable<String>('artist_id'),
            row.readNullable<String>('artist_name'),
            row.read<String>('artists'),
          ),
      ];
      // A handful of freshly written albums is cheaper to key here than to
      // copy into an isolate.
      final entries = raw.length > 64
          ? await Isolate.run(
              () => raw.map(albumArtistIndexEntry).toList(growable: false),
            )
          : raw.map(albumArtistIndexEntry).toList(growable: false);
      const chunkSize = 300;
      for (final chunk in chunked(entries, chunkSize)) {
        await customStatement(
          'INSERT INTO album_artist_index(album_id, source, artist_keys) '
          'VALUES ${List<String>.filled(chunk.length, '(?, ?, ?)').join(', ')} '
          'ON CONFLICT(album_id) DO UPDATE SET '
          'source = excluded.source, artist_keys = excluded.artist_keys',
          <Object?>[
            for (final entry in chunk) ...<Object?>[
              entry.albumId,
              entry.source,
              entry.artistKeys,
            ],
          ],
        );
      }
      written += rows.length;
      writtenIds.addAll(entries.map((entry) => entry.albumId));
      if (rows.length < batchSize) break;
    }
    if (written > 0) {
      await customStatement(
        'DELETE FROM album_artist_index '
        'WHERE album_id NOT IN (SELECT id FROM albums)',
      );
    }
    return written;
  }

  /// Visible albums that may belong to an artist page: those whose album
  /// artist or credits carry the artist's id or normalized name, plus
  /// [relatedAlbumIds]. [_buildArtistAlbumBuckets] then classifies them
  /// exactly as it would classify the whole library.
  Future<List<AlbumsTableData>> _artistAlbumCandidates({
    required String artistId,
    required String? artistName,
    required Iterable<String> relatedAlbumIds,
    bool refreshIndex = true,
  }) async {
    if (refreshIndex) await refreshAlbumArtistIndex();
    final idKey = '\u001fi:${artistId.trim()}\u001f';
    final name = normalizeMetadata(artistName ?? '');
    final byKey = await customSelect(
      '''
      SELECT a.* FROM albums a
      JOIN album_artist_index x ON x.album_id = a.id
      WHERE (a.is_provisional = 0 OR a.is_external = 1)
        AND (instr(x.artist_keys, ?) > 0 OR (? <> '' AND instr(x.artist_keys, ?) > 0))
      ''',
      variables: <Variable<Object>>[
        Variable<String>(idKey),
        Variable<String>(name),
        Variable<String>('\u001fn:$name\u001f'),
      ],
      readsFrom: {albumsTable, albumArtistIndexTable},
    ).map((row) => albumsTable.map(row.data)).get();
    final seen = byKey.map((album) => album.id).toSet();
    final missing = relatedAlbumIds
        .where((id) => id.isNotEmpty && !seen.contains(id))
        .toSet()
        .toList(growable: false);
    final related = <AlbumsTableData>[];
    for (final chunk in chunked(missing, _safeSqlVariableChunkSize)) {
      related.addAll(
        await (select(albumsTable)..where(
              (table) =>
                  table.id.isIn(chunk) &
                  (table.isProvisional.equals(false) |
                      table.isExternal.equals(true)),
            ))
            .get(),
      );
    }
    return <AlbumsTableData>[...byKey, ...related];
  }

  Future<ArtistAlbumBuckets> _loadArtistAlbumBuckets(
    String artistId,
    String? artistName,
  ) async {
    final related = await customSelect(
      '''
      SELECT DISTINCT album_id FROM songs
      WHERE artist_id = ?
        AND (is_provisional = 0 OR is_external = 1)
        AND server_deleted_at IS NULL
        AND album_id IS NOT NULL
      ''',
      variables: <Variable<Object>>[Variable<String>(artistId)],
      readsFrom: {songsTable},
    ).map((row) => row.read<String>('album_id').trim()).get();
    final relatedIds = related.where((id) => id.isNotEmpty).toSet();
    final candidates = await _artistAlbumCandidates(
      artistId: artistId,
      artistName: artistName,
      relatedAlbumIds: relatedIds,
    );
    return _buildArtistAlbumBuckets(
      albums: candidates,
      artistId: artistId,
      artistName: artistName,
      relatedSongAlbumIds: relatedIds,
    );
  }

  /// The artist page's primary and Featured In albums. Each album or song
  /// write re-reads only the artist's candidate albums (see
  /// [_artistAlbumCandidates]) at most four times a second, and a bucket set
  /// is emitted only when it changed.
  Stream<ArtistAlbumBuckets> watchArtistAlbumBuckets(String artistId) {
    final id = artistId.trim();
    if (id.isEmpty) {
      return Stream<ArtistAlbumBuckets>.value(const ArtistAlbumBuckets());
    }
    return watchArtistById(id)
        .map((artist) => artist?.name)
        .distinct()
        .switchMap(
          (artistName) =>
              tableUpdates(
                    TableUpdateQuery.onAllTables([albumsTable, songsTable]),
                  )
                  .map((_) => null)
                  .startWith(null)
                  .throttleTime(
                    const Duration(milliseconds: 250),
                    trailing: true,
                  )
                  .switchMap(
                    (_) => Stream.fromFuture(
                      _loadArtistAlbumBuckets(id, artistName),
                    ),
                  ),
        )
        .distinct(
          (a, b) =>
              _sameAlbums(a.primaryAlbums, b.primaryAlbums) &&
              _sameAlbums(a.featuredInAlbums, b.featuredInAlbums),
        );
  }

  static bool _sameAlbums(List<AlbumsTableData> a, List<AlbumsTableData> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// The artist page buckets computed by classifying every visible album in
  /// the library; the reference for [watchArtistAlbumBuckets] in tests.
  @visibleForTesting
  Future<ArtistAlbumBuckets> debugArtistAlbumBucketsByFullScan(
    String artistId,
  ) async {
    final id = artistId.trim();
    final artist = await getArtistById(id);
    final albums =
        await (select(albumsTable)..where(
              (table) =>
                  table.isProvisional.equals(false) |
                  table.isExternal.equals(true),
            ))
            .get();
    final songs = await watchSongsByArtist(id).first;
    return _buildArtistAlbumBuckets(
      albums: albums,
      artistId: id,
      artistName: artist?.name,
      relatedSongAlbumIds: songs
          .map((song) => song.albumId?.trim() ?? '')
          .where((albumId) => albumId.isNotEmpty)
          .toSet(),
    );
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
    return _watchAlbumsCustom(sort: AlbumSortOrder.newest, likedOnly: true);
  }

  Stream<List<AlbumsTableData>> watchLikedAlbums() {
    return _watchAlbumsCustom(sort: AlbumSortOrder.newest, likedOnly: true);
  }

  /// Watches explicitly starred albums, newest starred timestamp first.
  ///
  /// Equal timestamps use name then ID ordering. Pass a null [limit] to load
  /// the full collection before applying local filters and shelf capacity.
  Stream<List<AlbumsTableData>> watchRecentlyLikedAlbums({int? limit = 6}) {
    return customSelect(
      '''
      SELECT albums.* FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
      ORDER BY
        albums.starred DESC NULLS LAST,
        albums.name ASC,
        albums.id ASC
      ${limit == null ? '' : 'LIMIT ?'}
      ''',
      variables: [if (limit != null) Variable<int>(limit < 1 ? 1 : limit)],
      readsFrom: {albumsTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => albumsTable.map(row.data)).toList(growable: false),
    );
  }

  Stream<int> watchAlbumCount({bool likedOnly = false}) {
    if (!likedOnly) {
      final countExpression = albumsTable.id.count();
      final query = selectOnly(albumsTable)
        ..where(
          albumsTable.isProvisional.equals(false) &
              albumsTable.isExternal.equals(false),
        )
        ..addColumns([countExpression]);
      return query.watchSingle().map((row) => row.read(countExpression) ?? 0);
    }
    return customSelect(
      '''
      SELECT COUNT(*) AS count
      FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
      ''',
      readsFrom: {albumsTable},
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
        ..limit(limit < 1 ? 1 : limit, offset: offset < 0 ? 0 : offset);
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

  /// Download progress for every album that has a permanently downloaded or
  /// queued track. Albums without download activity are omitted. Counts use
  /// the same track set as an album's detail list.
  Stream<List<AlbumDownloadSummary>> watchAlbumDownloadSummaries() {
    return customSelect(
      '''
      WITH active_albums AS (
        SELECT DISTINCT s.album_id FROM songs s
        WHERE s.album_id IS NOT NULL AND s.id IN (
          SELECT song_id FROM cached_tracks WHERE cache_type = 'permanent'
          UNION
          SELECT song_id FROM download_queue WHERE song_id IS NOT NULL
        )
      ),
      queue AS (
        SELECT song_id, status, progress FROM download_queue
        WHERE id IN (
          SELECT MAX(id) FROM download_queue
          WHERE song_id IS NOT NULL
          GROUP BY song_id
        )
      )
      SELECT s.album_id AS album_id,
        COUNT(*) AS total,
        SUM(CASE WHEN c.cache_type = 'permanent' THEN 1 ELSE 0 END)
          AS downloaded,
        SUM(CASE WHEN c.cache_type IS NOT 'permanent'
            AND q.status = 'downloading'
          THEN MIN(MAX(q.progress, 0.0), 1.0) ELSE 0.0 END) AS in_flight,
        MAX(CASE WHEN c.cache_type IS NOT 'permanent'
            AND q.status IN ('downloading', 'queued', 'failed')
          THEN 1 ELSE 0 END) AS queued
      FROM songs s
      JOIN active_albums a ON a.album_id = s.album_id
      LEFT JOIN cached_tracks c ON c.song_id = s.id
      LEFT JOIN queue q ON q.song_id = s.id
      WHERE (s.is_provisional = 0 OR s.is_external = 1)
        AND s.server_deleted_at IS NULL
      GROUP BY s.album_id
      ''',
      readsFrom: {songsTable, cachedTracksTable, downloadQueueTable},
    ).watch().map(
      (rows) => <AlbumDownloadSummary>[
        for (final row in rows)
          AlbumDownloadSummary(
            albumId: row.read<String>('album_id'),
            totalTrackCount: row.read<int>('total'),
            downloadedTrackCount: row.read<int>('downloaded'),
            inFlightProgress: row.read<double>('in_flight'),
            queued: row.read<int>('queued') == 1,
          ),
      ],
    );
  }

  /// Whether Instant Radio has at least one eligible local song: a catalog
  /// song, or a downloaded one retained after server deletion, optionally
  /// restricted to liked and/or downloaded songs.
  Stream<bool> watchHasRadioCandidate({
    required bool likedOnly,
    required bool downloadedOnly,
  }) {
    return customSelect(
      '''
      SELECT EXISTS (
        SELECT 1 FROM songs s
        WHERE s.is_external = 0
          AND s.is_provisional = 0
          AND (
            s.server_deleted_at IS NULL
            OR s.id IN (SELECT song_id FROM cached_tracks)
          )
          ${likedOnly ? 'AND s.starred IS NOT NULL' : ''}
          ${downloadedOnly ? "AND s.id IN (SELECT song_id FROM cached_tracks WHERE cache_type = 'permanent')" : ''}
      ) AS has_candidate
      ''',
      readsFrom: {songsTable, cachedTracksTable},
    ).watchSingle().map((row) => row.read<bool>('has_candidate'));
  }

  /// Songs that are permanently downloaded or in the download queue, keyed
  /// by ID. One query replaces a per-row song watch on the Downloads screen.
  Stream<Map<String, SongsTableData>> watchDownloadRelatedSongs() {
    return customSelect(
      '''
      SELECT s.* FROM songs s
      WHERE s.id IN (
        SELECT song_id FROM cached_tracks WHERE cache_type = 'permanent'
        UNION
        SELECT song_id FROM download_queue WHERE song_id IS NOT NULL
      )
      ''',
      readsFrom: {songsTable, cachedTracksTable, downloadQueueTable},
    ).watch().map(
      (rows) => <String, SongsTableData>{
        for (final row in rows)
          row.read<String>('id'): songsTable.map(row.data),
      },
    );
  }

  /// How many songs [watchSongsByAlbum] lists for [albumId].
  Future<int> countSongsByAlbum(String albumId) async {
    final count = songsTable.id.count();
    final query = selectOnly(songsTable)
      ..addColumns([count])
      ..where(
        songsTable.albumId.equals(albumId) &
            (songsTable.isProvisional.equals(false) |
                songsTable.isExternal.equals(true)) &
            songsTable.serverDeletedAt.isNull(),
      );
    return (await query.getSingle()).read(count) ?? 0;
  }

  Stream<List<SongsTableData>> watchSongsByAlbum(String albumId) {
    final query = select(songsTable)
      ..where(
        (table) =>
            table.albumId.equals(albumId) &
            (table.isProvisional.equals(false) |
                table.isExternal.equals(true)) &
            table.serverDeletedAt.isNull(),
      )
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
        AND (s.is_provisional = 0 OR s.is_external = 1)
        AND s.server_deleted_at IS NULL
      ORDER BY
        al.year IS NULL ASC,
        al.year ASC,
        s.album_name IS NULL ASC,
        s.album_name ASC,
        COALESCE(s.disc_number, 1) ASC,
        s.track IS NULL ASC,
        s.track ASC,
        s.id ASC
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

  /// Album and artist ids of permanently downloaded songs, for the
  /// "Downloaded only" library filters.
  Stream<({Set<String> albumIds, Set<String> artistIds})>
  watchDownloadedContentIds() {
    return customSelect(
      '''
      SELECT DISTINCT songs.album_id AS album_id, songs.artist_id AS artist_id
      FROM cached_tracks c
      JOIN songs ON songs.id = c.song_id
      WHERE c.cache_type = ?
      ''',
      variables: <Variable<Object>>[Variable<String>(CacheType.permanent.name)],
      readsFrom: {cachedTracksTable, songsTable},
    ).watch().map((rows) {
      final albumIds = <String>{};
      final artistIds = <String>{};
      for (final row in rows) {
        final albumId = row.readNullable<String>('album_id');
        final artistId = row.readNullable<String>('artist_id');
        if (albumId != null) albumIds.add(albumId);
        if (artistId != null) artistIds.add(artistId);
      }
      return (albumIds: albumIds, artistIds: artistIds);
    });
  }

  /// Catalogue songs whose normalized title (the `normalizeSearchText` form
  /// kept in `song_search_text`) equals [titleKey], with their normalized
  /// artist, for matching files in a downloads folder by name. One indexed
  /// range read; rows whose index entry is stale are not returned, so callers
  /// refresh the index first.
  Future<List<({DownloadReconciliationSong song, String artistKey})>>
  getDownloadReconciliationSongsByTitleKey(String titleKey) async {
    if (titleKey.isEmpty) {
      return const <({DownloadReconciliationSong song, String artistKey})>[];
    }
    final prefix = '$titleKey$songSearchFieldSeparator';
    final rows = await customSelect(
      '''
      SELECT songs.id AS id, songs.title AS title,
        songs.artist_name AS artist_name, songs.suffix AS suffix,
        t.search_text AS search_text
      FROM song_search_text t
      -- CROSS JOIN keeps the title range on the index as the outer loop;
      -- otherwise SQLite may scan every song (about 500 times slower).
      CROSS JOIN songs ON songs.id = t.song_id
      WHERE t.search_text >= ? AND t.search_text < ?
        AND t.source = ($_songSearchSourceSql)
        AND songs.server_deleted_at IS NULL AND songs.is_provisional = 0
      ''',
      variables: <Variable<Object>>[
        Variable<String>(prefix),
        Variable<String>('$prefix\u{10FFFF}'),
      ],
      readsFrom: {songsTable, songSearchTextTable},
    ).get();
    return <({DownloadReconciliationSong song, String artistKey})>[
      for (final row in rows)
        (
          song: DownloadReconciliationSong(
            id: row.read<String>('id'),
            title: row.read<String>('title'),
            artistName: row.readNullable<String>('artist_name'),
            suffix: row.readNullable<String>('suffix'),
          ),
          artistKey: row
              .read<String>('search_text')
              .split(songSearchFieldSeparator)
              .elementAt(1),
        ),
    ];
  }

  /// Whether [songId] is a catalogue song a download can be matched to.
  Future<bool> isDownloadReconciliationSong(String songId) async {
    final row = await customSelect(
      '''
      SELECT 1 AS found FROM songs
      WHERE id = ? AND server_deleted_at IS NULL AND is_provisional = 0
      LIMIT 1
      ''',
      variables: <Variable<Object>>[Variable<String>(songId)],
      readsFrom: {songsTable},
    ).getSingleOrNull();
    return row != null;
  }

  /// Candidate results for a manual download-file mapping. Exact title matches
  /// are returned before related matches; liked songs and liked-album tracks
  /// are ranked first within each group.
  Future<List<SongsTableData>> searchDownloadReconciliationCandidates(
    String query, {
    int limit = 60,
  }) async {
    final normalized = _asciiSearchText(query);
    if (normalized.isEmpty || limit < 1) return const <SongsTableData>[];
    final pattern = '%$normalized%';
    final rows = await customSelect(
      '''
      SELECT s.*,
        CASE WHEN s.starred IS NOT NULL OR al.starred IS NOT NULL THEN 0 ELSE 1 END AS liked_rank,
        CASE
          WHEN LOWER(s.title) = ?1 THEN 0
          WHEN LOWER(s.title) LIKE ?2 || '%' THEN 1
          WHEN LOWER(s.title) LIKE ?3 THEN 2
          ELSE 3
        END AS title_rank
      FROM songs s
      LEFT JOIN albums al ON al.id = s.album_id
      WHERE s.server_deleted_at IS NULL
        AND s.is_provisional = 0
        AND (
          LOWER(s.title) LIKE ?3 OR LOWER(COALESCE(s.artist_name, '')) LIKE ?3
          OR LOWER(COALESCE(s.album_name, '')) LIKE ?3
        )
      ORDER BY title_rank ASC, liked_rank ASC, LOWER(s.title) ASC, s.id ASC
      LIMIT ?4
      ''',
      variables: <Variable<Object>>[
        Variable<String>(normalized),
        Variable<String>(normalized),
        Variable<String>(pattern),
        Variable<int>(limit),
      ],
      readsFrom: {songsTable, albumsTable},
    ).get();
    return rows.map((row) => songsTable.map(row.data)).toList(growable: false);
  }

  Future<Set<String>> getLikedSongIdsForDownloadReconciliation() async {
    final rows = await customSelect(
      '''
      SELECT s.id
      FROM songs s
      LEFT JOIN albums al ON al.id = s.album_id
      WHERE s.server_deleted_at IS NULL AND s.is_provisional = 0
        AND (s.starred IS NOT NULL OR al.starred IS NOT NULL)
      ''',
      readsFrom: {songsTable, albumsTable},
    ).get();
    return rows.map((row) => row.read<String>('id')).toSet();
  }

  /// Reads catalog songs in the requested order, optionally bounded.
  ///
  /// [onlyIds] restricts the result to those songs, in catalog order.
  Future<List<SongsTableData>> getSongsSorted(
    SongSortOrder sort, {
    int? limit,
    Set<String>? onlyIds,
  }) async {
    if (onlyIds != null && onlyIds.isEmpty) return const <SongsTableData>[];
    final query = _songsSortedQuery(sort);
    if (onlyIds != null) {
      query.where((table) => table.id.isIn(onlyIds));
    }
    if (limit != null) query.limit(limit);
    return query.get();
  }

  /// Up to [limit] random catalog songs, chosen in SQL.
  Future<List<SongsTableData>> getRandomSongs(int limit) {
    final query = select(songsTable)
      ..where(
        (table) =>
            table.serverDeletedAt.isNull() & table.isProvisional.equals(false),
      )
      ..orderBy([(_) => OrderingTerm.random()])
      ..limit(limit);
    return query.get();
  }

  SimpleSelectStatement<$SongsTableTable, SongsTableData> _songsSortedQuery(
    SongSortOrder sort,
  ) {
    final query = select(songsTable)
      ..where(
        (table) =>
            table.serverDeletedAt.isNull() & table.isProvisional.equals(false),
      );
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
    return query;
  }

  Future<void> replaceArtists(List<ArtistsTableCompanion> artists) async {
    await transaction(() async {
      await delete(artistsTable).go();
      await batch((batch) {
        batch.insertAll(artistsTable, artists);
      });
    });
  }

  /// Reclassify only IDs explicitly identified as external by a current
  /// server response. Retain all rows, relationships, annotations and files.
  /// Callers can inspect counts without mutation before applying the evidence.
  Future<Map<String, int>> repairExternalSourceEvidence({
    Iterable<String> artistIds = const [],
    Iterable<String> albumIds = const [],
    Iterable<String> songIds = const [],
    bool dryRun = false,
    int? serverId,
  }) => transaction(() async {
    final counts = <String, int>{};
    for (final entry in <String, Iterable<String>>{
      'artists': artistIds,
      'albums': albumIds,
      'songs': songIds,
    }.entries) {
      final ids = entry.value
          .where((id) => id.trim().isNotEmpty)
          .toSet()
          .toList();
      var count = 0;
      for (
        var offset = 0;
        offset < ids.length;
        offset += _safeSqlVariableChunkSize
      ) {
        final chunk = ids.skip(offset).take(_safeSqlVariableChunkSize).toList();
        final placeholders = List.filled(chunk.length, '?').join(',');
        final variables = chunk.map(Variable.withString).toList();
        final predicate =
            'id IN ($placeholders) AND (is_provisional = 0 OR is_external = 0)';
        final row = await customSelect(
          'SELECT COUNT(*) AS n FROM ${entry.key} WHERE $predicate',
          variables: variables,
        ).getSingle();
        count += row.read<int>('n');
        if (!dryRun && row.read<int>('n') > 0) {
          await customUpdate(
            'UPDATE ${entry.key} SET is_provisional = 1, is_external = 1 WHERE $predicate',
            variables: variables,
            updates: {artistsTable, albumsTable, songsTable},
          );
        }
      }
      counts[entry.key] = count;
    }
    if (!dryRun &&
        serverId != null &&
        counts.values.any((count) => count > 0)) {
      await attachedDatabase.librarySyncDao.recordOperationLedgerEntry(
        serverId: serverId,
        operation: 'sourceEvidenceRepair',
        reason: 'explicitExternalResponse',
        details: counts,
      );
    }
    return counts;
  });

  Future<void> upsertArtists(
    List<ArtistsTableCompanion> artists, {
    DateTime? snapshotStartedAt,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      if (artists.isEmpty) {
        return;
      }
      final external = artists
          .where(
            (row) => isExternalCatalogSource(
              id: row.id.value,
              apiIsExternal: row.isExternal.present
                  ? row.isExternal.value
                  : null,
            ),
          )
          .toList(growable: false);
      await upsertProvisionalArtists(
        external
            .map((row) => row.copyWith(isExternal: const Value(true)))
            .toList(growable: false),
        snapshotStartedAt: snapshotStartedAt,
      );
      final externalIds = external.map((row) => row.id.value).toSet();
      await batch((batch) {
        for (final artist in artists) {
          if (externalIds.contains(artist.id.value)) continue;
          var canonicalArtist = artist.copyWith(
            isProvisional: const Value(false),
            isExternal: const Value(false),
          );
          canonicalArtist = guard.artist(canonicalArtist);
          batch.insert(
            artistsTable,
            canonicalArtist,
            // Keep the primary key out of metadata updates: even id = id
            // makes SQLite recheck child foreign keys across the library.
            onConflict: DoUpdate(
              (old) => canonicalArtist.copyWith(id: const Value.absent()),
              target: [artistsTable.id],
            ),
          );
        }
      });
    });
  }

  Future<void> upsertProvisionalArtists(
    List<ArtistsTableCompanion> artists, {
    DateTime? snapshotStartedAt,
    bool preserveKnownMetadata = false,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      for (final artist in artists) {
        if (!artist.id.present) {
          continue;
        }
        final existing = await getArtistById(artist.id.value);
        if (existing != null && !existing.isProvisional) {
          continue;
        }
        if (preserveKnownMetadata && existing != null) {
          await (update(
            artistsTable,
          )..where((t) => t.id.equals(artist.id.value))).write(
            ArtistsTableCompanion(
              starred: artist.starred.present
                  ? artist.starred
                  : const Value.absent(),
            ),
          );
          continue;
        }
        final provisionalArtist = guard
            .artist(artist)
            .copyWith(isProvisional: Value(existing?.isProvisional ?? true));
        await into(artistsTable).insert(
          provisionalArtist,
          onConflict: DoUpdate(
            (old) => provisionalArtist.copyWith(id: const Value.absent()),
            target: [artistsTable.id],
          ),
        );
      }
    });
  }

  Future<void> upsertAlbums(
    List<AlbumsTableCompanion> albums, {
    bool preserveHydrationState = true,
    DateTime? snapshotStartedAt,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      if (albums.isEmpty) {
        return;
      }
      final now = DateTime.now();
      final external = albums
          .where(
            (row) => isExternalCatalogSource(
              id: row.id.value,
              apiIsExternal: row.isExternal.present
                  ? row.isExternal.value
                  : null,
            ),
          )
          .toList(growable: false);
      await upsertProvisionalAlbums(
        external
            .map((row) => row.copyWith(isExternal: const Value(true)))
            .toList(growable: false),
        snapshotStartedAt: snapshotStartedAt,
      );
      final externalIds = external.map((row) => row.id.value).toSet();
      await batch((batch) {
        for (final album in albums) {
          if (externalIds.contains(album.id.value)) continue;
          var canonicalAlbum = album.copyWith(
            syncedAt: Value(now),
            isProvisional: const Value(false),
            isExternal: const Value(false),
          );
          // getAlbum and older Subsonic implementations may omit `created`.
          // Absence is not deletion authority: preserving the existing server
          // timestamp keeps Recently Added stable across detail hydration.
          if (!canonicalAlbum.serverCreatedAt.present ||
              canonicalAlbum.serverCreatedAt.value == null) {
            canonicalAlbum = canonicalAlbum.copyWith(
              serverCreatedAt: const Value.absent(),
            );
          }
          canonicalAlbum = guard.album(canonicalAlbum);
          batch.insert(
            albumsTable,
            canonicalAlbum,
            onConflict: DoUpdate(
              (old) => canonicalAlbum.copyWith(
                id: const Value.absent(),
                syncedAt: const Value.absent(),
                songsHydrated: preserveHydrationState
                    ? const Value.absent()
                    : canonicalAlbum.songsHydrated,
              ),
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
    });
  }

  /// Atomically replaces Recently Added order with a server `newest` snapshot.
  ///
  /// A rank is the primary ordering authority. Albums outside the observed
  /// snapshot deliberately remain unranked and sort by their server creation
  /// date, never by the local synchronization time.
  Future<void> replaceRecentlyAddedRanksFromNewestFeed(
    Map<String, int> ranks, {
    bool complete = true,
  }) async {
    final normalizedRanks = <String, int>{
      for (final entry in ranks.entries)
        if (entry.key.trim().isNotEmpty && entry.value >= 0)
          entry.key.trim(): entry.value,
    };
    if (!complete && normalizedRanks.isEmpty) return;
    await transaction(() async {
      // Ordering needs two scalar columns. Loading full album metadata here
      // needlessly transfers and decodes the entire library on each check.
      final query = selectOnly(albumsTable)
        ..addColumns([albumsTable.id, albumsTable.recentlyAddedRank])
        ..where(
          albumsTable.isExternal.equals(false) &
              albumsTable.isProvisional.equals(false),
        );
      final rows = (await query.get())
          .map(
            (row) => (
              id: row.read(albumsTable.id)!,
              recentlyAddedRank: row.read(albumsTable.recentlyAddedRank),
            ),
          )
          .toList(growable: false);
      final byId = {for (final row in rows) row.id: row};
      final nextRanks = <String, int>{};
      if (complete) {
        nextRanks.addAll(normalizedRanks);
      } else {
        final prefix =
            normalizedRanks.entries
                .where((entry) => byId.containsKey(entry.key))
                .toList()
              ..sort((a, b) => a.value.compareTo(b.value));
        final tail =
            rows
                .where(
                  (row) =>
                      row.recentlyAddedRank != null &&
                      !normalizedRanks.containsKey(row.id),
                )
                .toList()
              ..sort((a, b) {
                final rank = a.recentlyAddedRank!.compareTo(
                  b.recentlyAddedRank!,
                );
                return rank == 0 ? a.id.compareTo(b.id) : rank;
              });
        final ordered = [
          ...prefix.map((entry) => entry.key),
          ...tail.map((row) => row.id),
        ];
        for (var index = 0; index < ordered.length; index++) {
          nextRanks[ordered[index]] = index;
        }
      }
      await batch((batch) {
        for (final row in rows) {
          final nextRank = nextRanks[row.id];
          if (nextRank == row.recentlyAddedRank) continue;
          batch.update(
            albumsTable,
            AlbumsTableCompanion(recentlyAddedRank: Value(nextRank)),
            where: (table) => table.id.equals(row.id),
          );
        }
      });
    });
  }

  Future<void> upsertProvisionalAlbums(
    List<AlbumsTableCompanion> albums, {
    DateTime? snapshotStartedAt,
    bool preserveKnownMetadata = false,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      final now = DateTime.now();
      for (final album in albums) {
        if (!album.id.present) {
          continue;
        }
        final existing = await getAlbumById(album.id.value);
        if (existing != null && !existing.isProvisional) {
          continue;
        }
        if (preserveKnownMetadata && existing != null) {
          await (update(
            albumsTable,
          )..where((t) => t.id.equals(album.id.value))).write(
            AlbumsTableCompanion(
              starred: album.starred.present
                  ? album.starred
                  : const Value.absent(),
              userRating: album.userRating.present
                  ? album.userRating
                  : const Value.absent(),
            ),
          );
          continue;
        }
        final provisionalAlbum = guard
            .album(album)
            .copyWith(
              syncedAt: Value(now),
              isProvisional: Value(existing?.isProvisional ?? true),
            );
        await into(albumsTable).insert(
          provisionalAlbum,
          onConflict: DoUpdate(
            (old) => provisionalAlbum.copyWith(id: const Value.absent()),
            target: [albumsTable.id],
          ),
        );
      }
    });
  }

  /// Keeps externally sourced releases available from their artist without
  /// admitting them into the server-backed Albums library.
  Future<void> markAlbumsExternalAndProvisional(Iterable<String> albumIds) {
    final ids = albumIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) return Future<void>.value();
    return (update(albumsTable)..where((table) => table.id.isIn(ids))).write(
      const AlbumsTableCompanion(
        isExternal: Value(true),
        isProvisional: Value(true),
      ),
    );
  }

  /// Oldest complete snapshots first; null is legacy/unverified evidence.
  Future<List<String>> getAlbumsDueForSongVerification({
    required DateTime before,
    required int limit,
  }) async {
    final rows =
        await (select(albumsTable)
              ..where(
                (table) =>
                    table.isProvisional.equals(false) &
                    table.isExternal.equals(false) &
                    table.songsHydrated.equals(true) &
                    (table.songsVerifiedAt.isNull() |
                        table.songsVerifiedAt.isSmallerOrEqualValue(before)),
              )
              ..orderBy([
                (table) => OrderingTerm.asc(table.songsVerifiedAt),
                (table) => OrderingTerm.asc(table.id),
              ])
              ..limit(limit))
            .get();
    return rows.map((row) => row.id).toList(growable: false);
  }

  /// Reconciles membership and returns files released by removed rows.
  ///
  /// The caller cleans them up only after its outer transaction commits.
  Future<List<String>> reconcileSongsForAlbumsChunk(
    Map<String, List<SongsTableCompanion>> songsByAlbumId, {
    bool markAlbumsHydrated = false,
    List<AlbumsTableCompanion> albumMetadata = const <AlbumsTableCompanion>[],
    DateTime? snapshotStartedAt,
    List<String>? deferredCacheFiles,
    int? serverId,
  }) async {
    final albumIds = songsByAlbumId.keys
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (albumIds.isEmpty) {
      return const <String>[];
    }

    final cacheFiles = <String>[];
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      for (final row in [
        ...albumMetadata,
        ...songsByAlbumId.values.expand((rows) => rows),
      ]) {
        // Validate typed companions below before any destructive mutation.
        if (row is AlbumsTableCompanion &&
                isExternalCatalogSource(
                  id: row.id.value,
                  apiIsExternal: row.isExternal.present
                      ? row.isExternal.value
                      : null,
                ) ||
            row is SongsTableCompanion &&
                isExternalCatalogSource(
                  id: row.id.value,
                  apiIsExternal: row.isExternal.present
                      ? row.isExternal.value
                      : null,
                )) {
          throw const SubsonicIncompleteResponseException(
            'External metadata cannot replace canonical membership.',
          );
        }
      }
      if (albumMetadata.isNotEmpty) {
        final now = DateTime.now();
        await batch((batch) {
          for (final album in albumMetadata) {
            var canonical = album.copyWith(
              syncedAt: Value(now),
              isProvisional: const Value(false),
              isExternal: const Value(false),
            );
            // getAlbum may omit `created` even when a prior catalog response
            // supplied it. Keep the known server date so targeted hydration
            // cannot collapse Recently Added into its alphabetical tie-breaker.
            if (!canonical.serverCreatedAt.present ||
                canonical.serverCreatedAt.value == null) {
              canonical = canonical.copyWith(
                serverCreatedAt: const Value.absent(),
              );
            }
            canonical = guard.album(canonical);
            batch.insert(
              albumsTable,
              canonical,
              onConflict: DoUpdate(
                (old) => canonical.copyWith(
                  id: const Value.absent(),
                  syncedAt: const Value.absent(),
                  songsHydrated: const Value.absent(),
                ),
                target: [albumsTable.id],
              ),
            );
          }
        });
      }
      final existingRows = await (select(
        songsTable,
      )..where((table) => table.albumId.isIn(albumIds))).get();
      final incomingIds = songsByAlbumId.values
          .expand((rows) => rows)
          .where((row) => row.id.present)
          .map((row) => row.id.value)
          .toSet();
      final removedRows = existingRows
          .where((row) => !row.isProvisional && !incomingIds.contains(row.id))
          .toList(growable: false);

      cacheFiles.addAll(
        (await retainOrRemoveServerSongs(removedRows)).deferredCacheFiles,
      );
      if (serverId != null && removedRows.isNotEmpty) {
        await attachedDatabase.librarySyncDao.recordOperationLedgerEntry(
          serverId: serverId,
          operation: 'albumReconciliation',
          reason: 'validatedDetail',
          details: {
            'albums': albumIds.length,
            'removedSongs': removedRows.length,
          },
        );
      }

      final currentSongs = songsByAlbumId.values
          .expand((rows) => rows)
          .map((song) {
            final canonical = song.copyWith(
              serverDeletedAt: const Value(null),
              isProvisional: const Value(false),
              isExternal: const Value(false),
            );
            return guard.song(canonical);
          })
          .toList(growable: false);
      if (currentSongs.isNotEmpty) {
        await batch((batch) {
          for (final song in currentSongs) {
            batch.insert(
              songsTable,
              song,
              onConflict: DoUpdate(
                (old) => song.copyWith(id: const Value.absent()),
                target: [songsTable.id],
              ),
            );
          }
        });
      }
      if (markAlbumsHydrated) {
        await (update(
          albumsTable,
        )..where((table) => table.id.isIn(albumIds))).write(
          AlbumsTableCompanion(
            songsHydrated: const Value(true),
            songsVerifiedAt: Value(snapshotStartedAt ?? DateTime.now()),
          ),
        );
      }
    });
    if (deferredCacheFiles != null) {
      deferredCacheFiles.addAll(cacheFiles);
    }
    return cacheFiles;
  }

  Future<void> upsertSongs(
    List<SongsTableCompanion> songs, {
    DateTime? snapshotStartedAt,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      if (songs.isEmpty) {
        return;
      }
      final external = songs
          .where(
            (row) => isExternalCatalogSource(
              id: row.id.value,
              apiIsExternal: row.isExternal.present
                  ? row.isExternal.value
                  : null,
            ),
          )
          .toList(growable: false);
      await upsertProvisionalSongs(
        external
            .map((row) => row.copyWith(isExternal: const Value(true)))
            .toList(growable: false),
        snapshotStartedAt: snapshotStartedAt,
      );
      final externalIds = external.map((row) => row.id.value).toSet();
      await batch((batch) {
        for (final song in songs) {
          if (externalIds.contains(song.id.value)) continue;
          var canonicalSong = song.copyWith(
            serverDeletedAt: const Value(null),
            isProvisional: const Value(false),
            isExternal: const Value(false),
          );
          canonicalSong = guard.song(canonicalSong);
          batch.insert(
            songsTable,
            canonicalSong,
            onConflict: DoUpdate(
              (old) => canonicalSong.copyWith(id: const Value.absent()),
              target: [songsTable.id],
            ),
          );
        }
      });
    });
  }

  Future<void> upsertProvisionalSongs(
    List<SongsTableCompanion> songs, {
    DateTime? snapshotStartedAt,
    bool preserveKnownMetadata = false,
  }) async {
    await transaction(() async {
      final guard = await SnapshotWriteGuard.read(
        attachedDatabase,
        snapshotStartedAt,
      );
      for (final song in songs) {
        if (!song.id.present) {
          continue;
        }
        final existing = await getSongById(song.id.value);
        if (existing != null && !existing.isProvisional) {
          continue;
        }
        if (preserveKnownMetadata && existing != null) {
          // Partial reference snapshot: only annotation fields are
          // authoritative; richer known metadata stays untouched.
          await (update(
            songsTable,
          )..where((t) => t.id.equals(song.id.value))).write(
            SongsTableCompanion(
              starred: song.starred.present
                  ? song.starred
                  : const Value.absent(),
              userRating: song.userRating.present
                  ? song.userRating
                  : const Value.absent(),
            ),
          );
          continue;
        }
        final provisionalSong = guard
            .song(song)
            .copyWith(
              serverDeletedAt: const Value(null),
              isProvisional: Value(existing?.isProvisional ?? true),
            );
        await into(songsTable).insert(
          provisionalSong,
          onConflict: DoUpdate(
            (old) => provisionalSong.copyWith(id: const Value.absent()),
            target: [songsTable.id],
          ),
        );
      }
    });
  }

  late final _entityTables = <String, TableInfo<Table, Object?>>{
    'song': songsTable,
    'album': albumsTable,
    'artist': artistsTable,
  };

  TableInfo<Table, Object?> _entityTable(String type) =>
      _entityTables[type] ?? (throw ArgumentError.value(type, 'type'));

  /// Saves a local favorite and journals its intent against concurrent snapshots.
  Future<void> setEntityStarred(String type, String id, DateTime? at) =>
      _setEntityAnnotation(
        type,
        id,
        'starred',
        Variable<DateTime>(at),
        at == null ? 'unstar' : 'star',
      );

  Future<void> setEntityRating(String type, String id, int? rating) {
    if (type != 'song' && type != 'album') {
      throw ArgumentError.value(type, 'type');
    }
    return _setEntityAnnotation(
      type,
      id,
      'user_rating',
      Variable<int>(rating),
      'rating',
    );
  }

  Future<void> _setEntityAnnotation(
    String type,
    String id,
    String column,
    Variable<Object> value,
    String operation,
  ) {
    final table = _entityTable(type);
    return transaction(() async {
      await customUpdate(
        'UPDATE ${table.actualTableName} SET $column = ? WHERE id = ?',
        variables: [value, Variable<String>(id)],
        updates: {table},
        updateKind: UpdateKind.update,
      );
      await _recordLocalMutation(
        entityType: type,
        entityId: id,
        operation: operation,
      );
    });
  }

  Future<void> updateSongRecordingMbid(String songId, String recordingMbid) {
    return (update(songsTable)..where((t) => t.id.equals(songId))).write(
      SongsTableCompanion(recordingMbid: Value(recordingMbid)),
    );
  }

  Future<void> _recordLocalMutation({
    required String entityType,
    required String entityId,
    required String operation,
  }) async {
    await (delete(librarySyncLocalMutationsTable)..where(
          (table) =>
              table.entityType.equals(entityType) &
              table.entityId.equals(entityId) &
              table.operation.equals(operation == 'rating' ? 'rating' : 'star'),
        ))
        .go();
    await into(librarySyncLocalMutationsTable).insert(
      LibrarySyncLocalMutationsTableCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        operation: operation == 'rating' ? operation : 'star',
        createdAt: DateTime.now(),
      ),
    );
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
    bool instrumental = false,
    int ttlSeconds = 86400,
    int failureCount = 0,
    DateTime? lastFailedAt,
  }) {
    final entry = ExternalLyricsCacheTableCompanion.insert(
      songId: songId,
      source: source,
      syncedLyrics: Value(syncedLyrics),
      plainLyrics: Value(plainLyrics),
      instrumental: Value(instrumental),
      fetchedAt: DateTime.now(),
      ttlSeconds: Value(ttlSeconds),
      failureCount: Value(failureCount),
      lastFailedAt: Value(lastFailedAt),
    );
    return into(externalLyricsCacheTable)
        .insert(
          entry,
          onConflict: DoUpdate(
            (_) => entry,
            // Slower lookups must preserve real lyrics already resolved.
            where: (old) => (syncedLyrics?.trim().isNotEmpty ?? false)
                ? const Constant(true)
                : (old.syncedLyrics.isNull() |
                          old.syncedLyrics.trim().equals('')) &
                      (instrumental
                          ? old.plainLyrics.isNull() |
                                old.plainLyrics.trim().equals('')
                          : const Constant(true)),
          ),
        )
        .then((_) {});
  }

  /// One-shot fetch of the current `starred` value for a single song.
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

  Future<Set<String>> getStarredIds(String type) async {
    final table = _entityTable(type);
    final rows = await customSelect(
      'SELECT id FROM ${table.actualTableName} WHERE starred IS NOT NULL',
      readsFrom: {table},
    ).get();
    return rows.map((row) => row.read<String>('id')).toSet();
  }

  /// Applies server favorites and clears only durably confirmed absences.
  ///
  /// [excludeIds] protects pending local star operations.
  Future<void> batchReconcileStarred(
    String type,
    Map<String, DateTime?> starredMap, {
    Set<String> excludeIds = const <String>{},
    Set<String> confirmedAbsentIds = const <String>{},
  }) async {
    final table = _entityTable(type);
    await transaction(() async {
      final clearIds = confirmedAbsentIds.difference(excludeIds);
      if (clearIds.isNotEmpty) {
        await customUpdate(
          'UPDATE ${table.actualTableName} SET starred = NULL '
          'WHERE starred IS NOT NULL AND id IN (${List.filled(clearIds.length, '?').join(',')})',
          variables: clearIds.map(Variable<String>.new).toList(),
          updates: {table},
          updateKind: UpdateKind.update,
        );
      }
      for (final entry in starredMap.entries) {
        if (excludeIds.contains(entry.key)) continue;
        await customUpdate(
          'UPDATE ${table.actualTableName} SET starred = ? WHERE id = ?',
          variables: [
            Variable<DateTime>(entry.value),
            Variable<String>(entry.key),
          ],
          updates: {table},
          updateKind: UpdateKind.update,
        );
      }
    });
  }

  /// Watch songs that have been starred/liked, ordered by starred date
  /// (most recently starred first).
  Stream<List<SongsTableData>> watchStarredSongs({int limit = 5}) {
    final query = select(songsTable)
      ..where((t) => t.starred.isNotNull() & t.serverDeletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.starred)])
      ..limit(limit);
    return query.watch();
  }

  /// Watch all starred songs (no limit) for the full liked-tracks view.
  Stream<List<SongsTableData>> watchAllStarredSongs() {
    final query = select(songsTable)
      ..where((t) => t.starred.isNotNull() & _selectableForBulkUse)
      ..orderBy([(t) => OrderingTerm.desc(t.starred)]);
    return query.watch();
  }

  /// Watch all songs that belong to explicitly liked albums.
  ///
  /// Songs are ordered deterministically by liked-album recency, then album,
  /// then track position within each album.
  Stream<List<SongsTableData>> watchSongsFromLikedAlbums() {
    return customSelect(
      '''
      SELECT s.*
      FROM songs s
      INNER JOIN albums al ON al.id = s.album_id
      WHERE ${_likedAlbumPredicate('al')}
        AND s.server_deleted_at IS NULL
      ORDER BY
        al.starred DESC NULLS LAST,
        LOWER(COALESCE(al.name, '')) ASC,
        al.id ASC,
        s.disc_number IS NULL ASC,
        s.disc_number ASC,
        s.track IS NULL ASC,
        s.track ASC,
        LOWER(COALESCE(s.title, '')) ASC,
        s.id ASC
      ''',
      readsFrom: {songsTable, albumsTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => songsTable.map(row.data)).toList(growable: false),
    );
  }

  /// Watch songs ordered by play count descending.
  ///
  /// Ties break by most recent local play, then title, then identity, so
  /// equal counts keep a stable order across refreshes instead of leaving
  /// the section to SQLite's scan order.
  Stream<List<SongsTableData>> watchMostPlayedSongs({int? limit = 5}) {
    return customSelect(
      '''
      SELECT s.*
      FROM songs s
      LEFT JOIN (
        SELECT song_id, MAX(played_at) AS last_played_at
        FROM play_history
        GROUP BY song_id
      ) ph ON ph.song_id = s.id
      WHERE s.play_count > 0
        AND s.server_deleted_at IS NULL
        AND s.is_provisional = 0
      ORDER BY
        s.play_count DESC,
        ph.last_played_at IS NULL ASC,
        ph.last_played_at DESC,
        LOWER(COALESCE(s.title, '')) ASC,
        s.id ASC
      ${limit == null ? '' : 'LIMIT ?'}
      ''',
      variables: [if (limit != null) Variable.withInt(limit)],
      readsFrom: {songsTable, playHistoryTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => songsTable.map(row.data)).toList(growable: false),
    );
  }

  Future<List<ArtistsTableData>> getAllArtists() {
    final query = select(artistsTable)
      ..where((table) => table.isProvisional.equals(false));
    return query.get();
  }

  /// Up to [limit] artists the user listens to most: by the summed play
  /// count of their songs, liked artists first among equal counts, then by
  /// name. Artists without plays count only when liked.
  Future<List<ArtistsTableData>> getTopPlayedArtists({int limit = 30}) async {
    final rows = await customSelect(
      '''
      SELECT a.*
      FROM artists a
      LEFT JOIN (
        SELECT artist_id, SUM(play_count) AS plays
        FROM songs
        WHERE play_count > 0
          AND server_deleted_at IS NULL
          AND is_provisional = 0
        GROUP BY artist_id
      ) p ON p.artist_id = a.id
      WHERE a.is_provisional = 0
        AND (p.plays > 0 OR a.starred IS NOT NULL)
      ORDER BY
        COALESCE(p.plays, 0) DESC,
        a.starred IS NULL ASC,
        LOWER(a.name) ASC,
        a.id ASC
      LIMIT ?
      ''',
      variables: [Variable.withInt(limit)],
      readsFrom: {artistsTable, songsTable},
    ).get();
    return rows.map((row) => artistsTable.map(row.data)).toList();
  }

  /// Up to [limit] library artists, except [excludeIds], weighted by the
  /// library rather than by plays: most liked albums first, then most songs,
  /// then most albums. A liked album counts only when the server stores it
  /// and it is not confirmed missing. Remote artists, artists without songs
  /// or liked albums, and the placeholders "[Unknown Artist]" and "Various
  /// Artists" are left out. Fills [getTopPlayedArtists] for a library with
  /// little play history.
  Future<List<ArtistsTableData>> getArtistsByLibraryWeight({
    required int limit,
    Set<String> excludeIds = const <String>{},
  }) async {
    if (limit <= 0) return const <ArtistsTableData>[];
    final rows = await customSelect(
      '''
      SELECT a.*
      FROM artists a
      LEFT JOIN (
        SELECT artist_id, COUNT(*) AS songs
        FROM songs
        WHERE server_deleted_at IS NULL AND is_provisional = 0
        GROUP BY artist_id
      ) s ON s.artist_id = a.id
      LEFT JOIN (
        SELECT artist_id, COUNT(*) AS liked
        FROM albums
        WHERE starred IS NOT NULL AND is_provisional = 0 AND is_external = 0
          AND (catalog_availability IS NULL OR
               catalog_availability != 'confirmedMissing')
        GROUP BY artist_id
      ) l ON l.artist_id = a.id
      WHERE a.is_provisional = 0 AND a.is_external = 0
        AND (s.songs > 0 OR l.liked > 0)
        AND LOWER(TRIM(a.name)) NOT IN ('[unknown artist]', 'various artists')
        AND a.id NOT IN (SELECT value FROM json_each(?))
      ORDER BY
        COALESCE(l.liked, 0) DESC,
        COALESCE(s.songs, 0) DESC,
        COALESCE(a.album_count, 0) DESC,
        LOWER(a.name) ASC,
        a.id ASC
      LIMIT ?
      ''',
      variables: [
        Variable<String>(jsonEncode(excludeIds.toList(growable: false))),
        Variable.withInt(limit),
      ],
      readsFrom: {artistsTable, songsTable, albumsTable},
    ).get();
    return rows.map((row) => artistsTable.map(row.data)).toList();
  }

  /// Finds one exact normalized artist, falling back to a unique loose row.
  ///
  /// Duplicate rows on either path are ambiguous and return `null`.
  Future<ArtistsTableData?> findOneExactNormalizedArtistByName(
    String name,
  ) async {
    final normalizedName = _normalizeMetadataLookup(name);
    if (normalizedName.isEmpty) {
      return null;
    }

    return (await artistNameIndex.current()).lookupUnique(name);
  }

  Future<int> countArtists() async {
    final countExpression = artistsTable.id.count();
    final query = selectOnly(artistsTable)
      ..where(artistsTable.isProvisional.equals(false))
      ..addColumns([countExpression]);
    final row = await query.getSingle();
    final resolvedCount = row.read(countExpression) ?? 0;
    return resolvedCount;
  }

  Future<LibraryCatalogCounts> getCatalogCounts() async {
    final artistCount = artistsTable.id.count();
    final albumCount = albumsTable.id.count();
    final songCount = songsTable.id.count();
    final artistRow = await (selectOnly(
      artistsTable,
    )..addColumns([artistCount])).getSingle();
    final albumRow = await (selectOnly(
      albumsTable,
    )..addColumns([albumCount])).getSingle();
    final songRow = await (selectOnly(
      songsTable,
    )..addColumns([songCount])).getSingle();
    return LibraryCatalogCounts(
      artists: artistRow.read(artistCount) ?? 0,
      albums: albumRow.read(albumCount) ?? 0,
      songs: songRow.read(songCount) ?? 0,
    );
  }

  Future<List<SongsTableData>> getAllSongs() async {
    final rows = await customSelect(
      'SELECT * FROM ${songsTable.actualTableName} '
      'WHERE ${songsTable.serverDeletedAt.name} IS NULL '
      'AND ${songsTable.isProvisional.name} = 0',
      readsFrom: {songsTable},
    ).get();
    return await _mapSongRowsInChunks(rows);
  }

  Future<Set<String>> getArtistIds() async {
    final query = selectOnly(artistsTable)
      ..where(artistsTable.isProvisional.equals(false))
      ..addColumns([artistsTable.id]);
    final rows = await query.get();
    return rows
        .map((row) => row.read(artistsTable.id))
        .whereType<String>()
        .toSet();
  }

  Future<List<ArtistsTableData>> getArtistsByIds(
    Iterable<String> artistIds,
  ) async {
    final ids = artistIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) {
      return const <ArtistsTableData>[];
    }
    final rows = <ArtistsTableData>[
      for (final chunk in chunked(ids, _safeSqlVariableChunkSize))
        ...await (select(
          artistsTable,
        )..where((table) => table.id.isIn(chunk))).get(),
    ];
    final byId = <String, ArtistsTableData>{
      for (final row in rows) row.id: row,
    };
    return ids
        .map((id) => byId[id])
        .whereType<ArtistsTableData>()
        .toList(growable: false);
  }

  Future<List<AlbumsTableData>> getAllAlbums() {
    final query = select(albumsTable)
      ..where(
        (table) =>
            table.isProvisional.equals(false) & table.isExternal.equals(false),
      );
    return query.get();
  }

  Future<List<AlbumsTableData>> getAlbumsByIds(
    Iterable<String> albumIds,
  ) async {
    final ids = albumIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (ids.isEmpty) {
      return const <AlbumsTableData>[];
    }
    final rows = <AlbumsTableData>[
      for (final chunk in chunked(ids, _safeSqlVariableChunkSize))
        ...await (select(
          albumsTable,
        )..where((table) => table.id.isIn(chunk))).get(),
    ];
    final byId = <String, AlbumsTableData>{for (final row in rows) row.id: row};
    return ids
        .map((id) => byId[id])
        .whereType<AlbumsTableData>()
        .toList(growable: false);
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
        return _singleOrSameEdition(
          contextMatches,
          albumName,
          (album) => album.name,
          (album) => album.id,
          allowTies: true,
        );
      }
    }

    return _singleOrSameEdition(
      exactAlbums,
      albumName,
      (album) => album.name,
      (album) => album.id,
    );
  }

  Future<List<AlbumsTableData>> getLikedAlbums() {
    return customSelect(
      '''
      SELECT albums.*
      FROM albums
      WHERE ${_likedAlbumPredicate('albums')}
        AND (albums.catalog_availability IS NULL OR
             albums.catalog_availability != 'confirmedMissing')
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
      ..where((t) => t.starred.isNotNull() & _selectableForBulkUse)
      ..orderBy([(t) => OrderingTerm.desc(t.starred)]);
    return query.get();
  }

  /// Whether a song may appear in bulk/automatic selection (shuffle, Play
  /// All, auto-download): anything the catalog still lists, plus absent rows
  /// that hold a complete local copy so offline favorites stay playable
  /// (plan E4/E5). Suspicion alone never hides content.
  Expression<bool> get _selectableForBulkUse {
    const hasCompleteLocalCopy = CustomExpression<bool>(
      'EXISTS (SELECT 1 FROM cached_tracks c '
      "WHERE c.song_id = songs.id AND c.download_status = 'complete')",
    );
    // COALESCE keeps legacy NULL rows selectable; drift's NOT on a compound
    // expression does not parenthesize, so absence is spelled out directly.
    final listed =
        songsTable.serverDeletedAt.isNull() &
        const CustomExpression<bool>(
          "COALESCE(songs.catalog_availability, 'present') "
          "!= 'confirmedMissing'",
        );
    return listed | hasCompleteLocalCopy;
  }

  /// Records an isolated media-fetch 404 as suspicion (plan E2).
  ///
  /// Suspicion never hides content: the row stays selectable and playable
  /// from any local source, and only validated catalog evidence may confirm
  /// absence. Only rows still reading as present advance to suspicion; a
  /// later successful server observation clears it during promotion.
  Future<void> markSongsSuspectedMissing(Iterable<String> songIds) async {
    final ids = songIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) {
      return;
    }
    await (update(songsTable)..where(
          (t) =>
              t.id.isIn(ids) &
              (t.catalogAvailability.isNull() |
                  t.catalogAvailability.equals(
                    CatalogAvailability.present.name,
                  )),
        ))
        .write(
          SongsTableCompanion(
            catalogAvailability: Value(
              CatalogAvailability.suspectedMissing.name,
            ),
          ),
        );
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
      return _singleOrSameEdition(
        matches,
        title,
        (song) => song.title,
        (song) => song.id,
        // A shared name alone cannot establish artist or album identity.
        allowTies:
            (matches.first.artistId?.isNotEmpty ?? false) &&
                matches.every(
                  (song) => song.artistId == matches.first.artistId,
                ) ||
            (matches.first.albumId?.isNotEmpty ?? false) &&
                matches.every((song) => song.albumId == matches.first.albumId),
      );
    }

    return _singleOrSameEdition(
      exactSongs,
      title,
      (song) => song.title,
      (song) => song.id,
    );
  }

  /// The only entry of [matches], which share [name]'s normalized key, or
  /// else a candidate with the same edition as [name] ("Wonder
  /// (Japanese Version)" rather than "Wonder"). Within that edition, prefer
  /// the exact raw name, then the smallest id, only with artist/album context.
  /// Unfiltered edition ties and missing editions remain ambiguous.
  static T? _singleOrSameEdition<T>(
    List<T> matches,
    String name,
    String Function(T) nameOf,
    String Function(T) idOf, {
    bool allowTies = false,
  }) {
    if (matches.length == 1) return matches.single;
    final edition = normalizeMetadataKeepingEdition(name);
    final sameEdition = matches
        .where(
          (match) => normalizeMetadataKeepingEdition(nameOf(match)) == edition,
        )
        .toList(growable: false);
    if (sameEdition.isEmpty) return null;
    if (sameEdition.length == 1) return sameEdition.single;
    if (!allowTies) return null;
    sameEdition.sort((a, b) => idOf(a).compareTo(idOf(b)));
    return sameEdition.firstWhere(
      (match) => nameOf(match) == name,
      orElse: () => sameEdition.first,
    );
  }

  Future<List<SongsTableData>> getSongsByIds(
    Iterable<String> songIds, {
    bool includeLocalOnly = true,
  }) async {
    final ids = songIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return const <SongsTableData>[];
    }

    final byId = <String, SongsTableData>{};
    for (final chunk in chunked(idList, _safeSqlVariableChunkSize)) {
      final query = select(songsTable)
        ..where(
          (table) =>
              table.id.isIn(chunk) &
              (includeLocalOnly
                  ? const Constant<bool>(true)
                  : table.serverDeletedAt.isNull()),
        );
      for (final row in await query.get()) {
        byId[row.id] = row;
      }
    }
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

  /// Deletes albums and returns cache files for post-commit cleanup.
  Future<List<String>> deleteAlbumsByIds(Iterable<String> albumIds) async {
    final ids = albumIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return const <String>[];
    }
    final cacheFiles = <String>[];
    await transaction(() async {
      for (final chunk in chunked(ids, _safeSqlVariableChunkSize)) {
        final songs = await (select(
          songsTable,
        )..where((table) => table.albumId.isIn(chunk))).get();
        cacheFiles.addAll(
          (await retainOrRemoveServerSongs(songs)).deferredCacheFiles,
        );
        await (delete(
          albumsTable,
        )..where((table) => table.id.isIn(chunk))).go();
      }
    });
    return cacheFiles;
  }

  /// Removes artists whose dependent server songs and albums were already
  /// handled by a catalog-promotion transaction. Chunks stay below SQLite's
  /// bind-variable limit and avoid one nested transaction per stale artist.
  Future<void> deleteArtistsByIds(Iterable<String> artistIds) async {
    final ids = artistIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    const chunkSize = 500;
    for (final chunk in chunked(ids, chunkSize)) {
      await (delete(artistsTable)..where((table) => table.id.isIn(chunk))).go();
    }
  }

  Future<void> clearLibraryData() async {
    await transaction(() async {
      // Song deletion cascades to queue and playlist entries. Keep device-owned
      // references in place while server playlist contents are re-fetched.
      await customUpdate(
        'DELETE FROM songs WHERE id NOT IN '
        '(SELECT song_id FROM play_queue_items) '
        'AND id NOT IN (SELECT ps.song_id FROM playlist_songs ps '
        'JOIN playlists p ON p.id = ps.playlist_id WHERE p.is_local = 1)',
        updates: {songsTable},
        updateKind: UpdateKind.delete,
      );
      // Kept rows are references until the rebuild reconfirms them. Availability
      // distinguishes these provisional songs from playable search results,
      // and lets a complete scan reconcile them even without parent IDs.
      await update(songsTable)
          .write(const SongsTableCompanion(isProvisional: Value(true)));
      await (update(songsTable)..where(
            (table) =>
                table.isExternal.equals(false) & table.serverDeletedAt.isNull(),
          ))
          .write(
            SongsTableCompanion(
              catalogAvailability: Value(
                CatalogAvailability.pendingRebuild.name,
              ),
            ),
          );
      // Keep parent metadata for exact detail and identity reconciliation,
      // but force server-observed parents through the normal metadata upsert.
      await customUpdate(
        'DELETE FROM albums WHERE id NOT IN '
        '(SELECT album_id FROM songs WHERE album_id IS NOT NULL)',
        updates: {albumsTable},
        updateKind: UpdateKind.delete,
      );
      await customUpdate(
        'DELETE FROM artists WHERE id NOT IN ( '
        'SELECT artist_id FROM songs WHERE artist_id IS NOT NULL '
        'UNION SELECT artist_id FROM albums WHERE artist_id IS NOT NULL)',
        updates: {artistsTable},
        updateKind: UpdateKind.delete,
      );
      await update(albumsTable)
          .write(const AlbumsTableCompanion(isProvisional: Value(true)));
      await update(artistsTable)
          .write(const ArtistsTableCompanion(isProvisional: Value(true)));
    });
  }

  Future<PreservedProvisionalTree> preserveCachedLegacyRowsAsProvisional({
    required Iterable<String> staleArtistIds,
    required Iterable<String> staleAlbumIds,
    Iterable<String> protectedSongIds = const <String>[],
  }) async {
    final artistIds = staleArtistIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final albumIds = staleAlbumIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final protectedIds = protectedSongIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (artistIds.isEmpty && albumIds.isEmpty) {
      return const PreservedProvisionalTree();
    }

    // A server rebuild can make every album and artist stale at once, far
    // more ids than one statement may bind, so the ids go through a
    // temporary table and every query joins it.
    return transaction(() async {
      await _resetPreservationIds();
      await _fillPreservationIds(<String, List<String>>{
        'artist': artistIds,
        'album': albumIds,
        'song': protectedIds,
      });
      final rows = await customSelect(
        '''
        SELECT DISTINCT s.id, s.album_id, s.artist_id
        FROM songs s
        LEFT JOIN cached_tracks c ON c.song_id = s.id
        WHERE (
            c.download_status = 'complete'
            OR s.id IN (SELECT id FROM $_preservationIdsTable WHERE kind = 'song')
          )
          AND (
            s.artist_id IN (
              SELECT id FROM $_preservationIdsTable WHERE kind = 'artist'
            )
            OR s.album_id IN (
              SELECT id FROM $_preservationIdsTable WHERE kind = 'album'
            )
          );
        ''',
        readsFrom: {songsTable, cachedTracksTable},
      ).get();
      final cachedProtectedSongIds = rows
          .map((row) => row.read<String>('id'))
          .toSet();
      // Only stale parents are kept as provisional trees. A preserved song
      // may belong to an album or artist the new snapshot still has; that
      // parent and its other songs are current and stay canonical.
      final staleAlbums = albumIds.toSet();
      final staleArtists = artistIds.toSet();
      final protectedAlbumIds = rows
          .map((row) => row.readNullable<String>('album_id'))
          .whereType<String>()
          .where(staleAlbums.contains)
          .toSet();
      final protectedArtistIds = rows
          .map((row) => row.readNullable<String>('artist_id'))
          .whereType<String>()
          .where(staleArtists.contains)
          .toSet();
      if (cachedProtectedSongIds.isEmpty) {
        await _clearPreservationIds();
        return const PreservedProvisionalTree();
      }

      await _fillPreservationIds(<String, List<String>>{
        'protected-song': cachedProtectedSongIds.toList(growable: false),
        'protected-album': protectedAlbumIds.toList(growable: false),
        'protected-artist': protectedArtistIds.toList(growable: false),
      });
      final retainedRows = await customSelect(
        '''
        SELECT id FROM songs
        WHERE id IN (
            SELECT id FROM $_preservationIdsTable WHERE kind = 'protected-song'
          )
          OR album_id IN (
            SELECT id FROM $_preservationIdsTable WHERE kind = 'protected-album'
          )
          OR artist_id IN (
            SELECT id FROM $_preservationIdsTable WHERE kind = 'protected-artist'
          );
        ''',
        readsFrom: {songsTable},
      ).get();
      final retainedSongIds = retainedRows
          .map((row) => row.read<String>('id'))
          .toSet();
      await _fillPreservationIds(<String, List<String>>{
        'retained-song': retainedSongIds.toList(growable: false),
      });
      await customUpdate(
        '''
        UPDATE songs SET is_provisional = 1
        WHERE id IN (
          SELECT id FROM $_preservationIdsTable WHERE kind = 'retained-song'
        );
        ''',
        updates: {songsTable},
        updateKind: UpdateKind.update,
      );
      await customUpdate(
        '''
        UPDATE albums SET is_provisional = 1
        WHERE id IN (
          SELECT id FROM $_preservationIdsTable WHERE kind = 'protected-album'
        );
        ''',
        updates: {albumsTable},
        updateKind: UpdateKind.update,
      );
      await customUpdate(
        '''
        UPDATE artists SET is_provisional = 1
        WHERE id IN (
          SELECT id FROM $_preservationIdsTable WHERE kind = 'protected-artist'
        );
        ''',
        updates: {artistsTable},
        updateKind: UpdateKind.update,
      );
      await _clearPreservationIds();
      return PreservedProvisionalTree(
        artistIds: protectedArtistIds,
        albumIds: protectedAlbumIds,
        songIds: retainedSongIds,
      );
    });
  }

  static const _preservationIdsTable = 'temp.navis_preservation_ids';

  /// Adds ids to the connection-local table that
  /// [preserveCachedLegacyRowsAsProvisional] joins, in chunks within SQLite's
  /// bound-variable limit.
  Future<void> _fillPreservationIds(Map<String, List<String>> idsByKind) async {
    for (final MapEntry(key: kind, value: ids) in idsByKind.entries) {
      for (final chunk in chunked(ids, _safeSqlVariableChunkSize)) {
        await customStatement(
          'INSERT OR IGNORE INTO $_preservationIdsTable (kind, id) VALUES '
          '${List<String>.filled(chunk.length, '(?, ?)').join(', ')};',
          <Object?>[
            for (final id in chunk) ...<Object?>[kind, id],
          ],
        );
      }
    }
  }

  /// Creates the table on this connection if needed, empty. Temporary
  /// tables are per connection, so every use runs inside one transaction.
  Future<void> _resetPreservationIds() async {
    await customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS navis_preservation_ids '
      '(kind TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY (kind, id)) '
      'WITHOUT ROWID;',
    );
    await _clearPreservationIds();
  }

  Future<void> _clearPreservationIds() =>
      customStatement('DELETE FROM $_preservationIdsTable;');

  Future<void> deleteLocalOnlySong(String songId) async {
    final id = songId.trim();
    if (id.isEmpty) {
      return;
    }
    // A device playlist holds the only copy of its entries: keep their songs,
    // or the playlist_songs cascade would silently edit the playlist.
    await customUpdate(
      'DELETE FROM songs WHERE id = ? AND server_deleted_at IS NOT NULL '
      'AND id NOT IN (SELECT ps.song_id FROM playlist_songs ps '
      'JOIN playlists p ON p.id = ps.playlist_id WHERE p.is_local = 1)',
      variables: [Variable.withString(id)],
      updates: {songsTable, playlistSongsTable},
      updateKind: UpdateKind.delete,
    );
  }

  /// Removes songs that disappeared from a validated server snapshot.
  ///
  /// Songs with a valid permanent download keep their local row (the classic
  /// retention contract). Songs that still own user state — favorites,
  /// ratings, history, queue/playlist references, pending mutations, or
  /// download ownership — are retained as confirmed-missing so recovery review
  /// can offer replacements instead of silently destroying user data. Only
  /// unowned rows are deleted outright.
  Future<RetainedServerSongsResult> retainOrRemoveServerSongs(
    Iterable<SongsTableData> songs,
  ) async {
    final ids = songs
        .where((song) => song.serverDeletedAt == null)
        .map((song) => song.id)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) {
      return const RetainedServerSongsResult();
    }

    final now = DateTime.now();
    final deferredCacheFiles = <String>[];
    final retainedUnavailableIds = <String>[];
    const chunkSize = 500;
    for (final chunk in chunked(ids, chunkSize)) {
      final caches = await (select(
        cachedTracksTable,
      )..where((table) => table.songId.isIn(chunk))).get();
      final preservedIds = <String>{};
      for (final cache in caches) {
        final preserve =
            cache.cacheType == CacheType.permanent &&
            cache.downloadStatus == DownloadStatus.complete &&
            await storedAudioExists(
              locator: cache.filePath,
              storageKind: cache.storageKind,
            );
        if (preserve) {
          preservedIds.add(cache.songId);
        }
      }
      final ownedIds = await _ownedSongIds(
        chunk.where((id) => !preservedIds.contains(id)).toList(),
      );
      final retainedUnavailableIdsForChunk = ownedIds
          .where((id) => !preservedIds.contains(id))
          .toList(growable: false);
      retainedUnavailableIds.addAll(retainedUnavailableIdsForChunk);
      final keptIds = {...preservedIds, ...retainedUnavailableIdsForChunk};
      if (keptIds.isNotEmpty) {
        await (update(
          songsTable,
        )..where((table) => table.id.isIn(keptIds))).write(
          SongsTableCompanion(
            albumId: const Value(null),
            artistId: const Value(null),
            serverDeletedAt: Value(now),
            catalogAvailability: Value(
              CatalogAvailability.confirmedMissing.name,
            ),
          ),
        );
      }
      final removableIds = chunk
          .where(
            (id) =>
                !preservedIds.contains(id) &&
                !retainedUnavailableIdsForChunk.contains(id),
          )
          .toList(growable: false);
      if (removableIds.isEmpty) {
        continue;
      }
      final removableSet = removableIds.toSet();
      deferredCacheFiles.addAll(
        caches
            .where((cache) => removableSet.contains(cache.songId))
            .map((cache) => cache.filePath),
      );
      await (delete(
        cachedTracksTable,
      )..where((table) => table.songId.isIn(removableIds))).go();
      await (delete(
        downloadQueueTable,
      )..where((table) => table.songId.isIn(removableIds))).go();
      await (delete(
        externalLyricsCacheTable,
      )..where((table) => table.songId.isIn(removableIds))).go();
      await (delete(
        matchFlowSongsTable,
      )..where((table) => table.songId.isIn(removableIds))).go();
      await (delete(
        songsTable,
      )..where((table) => table.id.isIn(removableIds))).go();
    }
    return RetainedServerSongsResult(
      deferredCacheFiles: deferredCacheFiles,
      retainedUnavailableIds: retainedUnavailableIds,
    );
  }

  /// Song IDs among [ids] that still own local user state or references and
  /// must survive a validated server absence for recovery review.
  Future<Set<String>> _ownedSongIds(List<String> ids) async {
    if (ids.isEmpty) {
      return const <String>{};
    }
    final owned = <String>{};
    final metadataRows =
        await (select(songsTable)..where(
              (table) =>
                  table.id.isIn(ids) &
                  (table.starred.isNotNull() | table.userRating.isNotNull()),
            ))
            .get();
    owned.addAll(metadataRows.map((row) => row.id));
    final existsChecks = <String, String>{
      'play_history': 'SELECT 1 FROM play_history h WHERE h.song_id = s.id',
      'play_queue_items':
          'SELECT 1 FROM play_queue_items q WHERE q.song_id = s.id',
      'playlist_songs': 'SELECT 1 FROM playlist_songs p WHERE p.song_id = s.id',
      'download_queue': 'SELECT 1 FROM download_queue d WHERE d.song_id = s.id',
      'match_flow_songs':
          'SELECT 1 FROM match_flow_songs m WHERE m.song_id = s.id',
      'scrobble_queue':
          'SELECT 1 FROM scrobble_queue sq WHERE sq.song_id = s.id',
      'listenbrainz_feedback_queue':
          'SELECT 1 FROM listenbrainz_feedback_queue f WHERE f.song_id = s.id',
      'star_sync_queue':
          'SELECT 1 FROM star_sync_queue st '
          "WHERE st.item_type = 'song' AND st.item_id = s.id",
      'library_sync_local_mutations':
          'SELECT 1 FROM library_sync_local_mutations lm '
          "WHERE lm.entity_type = 'song' AND lm.entity_id = s.id",
    };
    final predicate = existsChecks.values
        .map((exists) => 'EXISTS ($exists)')
        .join(' OR ');
    for (final chunk in chunked(ids, 100)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await customSelect(
        'SELECT DISTINCT s.id FROM songs s '
        'WHERE s.id IN ($placeholders) AND ($predicate);',
        variables: <Variable<Object>>[
          for (final id in chunk) Variable<String>(id),
        ],
        readsFrom: {
          songsTable,
          playHistoryTable,
          playQueueItemsTable,
          playlistSongsTable,
          downloadQueueTable,
          matchFlowSongsTable,
          scrobbleQueueTable,
          listenBrainzFeedbackQueueTable,
          starSyncQueueTable,
        },
      ).get();
      owned.addAll(rows.map((row) => row.read<String>('id')));
    }
    return owned;
  }

  Future<void> cleanupRemovedCacheFiles(Iterable<String> paths) async {
    for (final path in paths.toSet()) {
      await _deleteCacheFileBestEffort(path);
    }
  }

  /// Bumps the targeted artwork refresh revision for the given entities.
  ///
  /// Used by explicit repairs: rows whose server metadata changed may also
  /// have new cover bytes behind an unchanged cover-art ID, and a bumped
  /// revision refetches exactly those entries without clearing any other
  /// cached artwork.
  Future<void> bumpCoverArtRevisions({
    Iterable<String> songIds = const <String>[],
    Iterable<String> albumIds = const <String>[],
    Iterable<String> artistIds = const <String>[],
  }) async {
    final idsByType = {
      for (final (type, ids) in [
        ('song', songIds),
        ('album', albumIds),
        ('artist', artistIds),
      ])
        type: ids.where((id) => id.isNotEmpty).toSet().toList(),
    };
    if (idsByType.values.every((ids) => ids.isEmpty)) return;
    await transaction(() async {
      for (final entry in idsByType.entries) {
        final ids = entry.value;
        final table = _entityTable(entry.key);
        for (final chunk in chunked(ids, _safeSqlVariableChunkSize)) {
          await customUpdate(
            'UPDATE ${table.actualTableName} SET cover_art_revision = '
            'COALESCE(cover_art_revision, 0) + 1 WHERE id IN '
            '(${List.filled(chunk.length, '?').join(',')});',
            variables: [for (final id in chunk) Variable.withString(id)],
            updates: {table},
            updateKind: UpdateKind.update,
          );
        }
      }
    });
  }

  Future<void> _deleteCacheFileBestEffort(String path) async {
    final normalized = path.trim();
    if (normalized.isEmpty) {
      return;
    }
    try {
      await deleteFileWithSuffixes(normalized);
    } on FileSystemException {
      // Cache metadata must not be kept alive by a failed best-effort unlink.
    }
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
            (t) => t.name.lower().like(pattern) & t.isProvisional.equals(false),
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
                (t.name.lower().like(pattern) |
                    t.artistName.lower().like(pattern)) &
                t.isProvisional.equals(false),
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
  ///
  /// Matching runs in SQL against the `song_search_text` index: each query
  /// token must be an in-order subsequence of the song's normalized text,
  /// which every ranked match satisfies. Only candidates are scored in Dart.
  /// Missing or stale index rows are normalized here and stored afterwards,
  /// so any songs write path stays correct without maintaining the index.
  Future<List<SongsTableData>> searchCachedSongs(
    String query, {
    int limit = 20,
    bool includeLocalOnly = false,
  }) async {
    if (limit < 1) return const <SongsTableData>[];
    final normalizedQuery = normalizeSearchText(query);
    if (normalizedQuery.isEmpty) {
      // Punctuation-only input matches nothing; it must not fall through to an
      // unrelated alphabetical list.
      if (query.trim().isNotEmpty) return const <SongsTableData>[];
      return await (select(songsTable)
            ..where(
              (t) => includeLocalOnly
                  ? _searchableSongPredicate()
                  : t.serverDeletedAt.isNull() & _searchableSongPredicate(),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.title),
              (t) => OrderingTerm.asc(t.id),
            ])
            ..limit(limit))
          .get();
    }

    final tokens = normalizedQuery
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    final rows = await customSelect(
      '''
      SELECT songs.id AS id, songs.title AS title,
        songs.artist_name AS artist_name, songs.album_name AS album_name,
        CASE WHEN $_songSearchTextCurrentSql
          THEN t.search_text END AS search_text
      FROM songs
      LEFT JOIN song_search_text t ON t.song_id = songs.id
      WHERE ${includeLocalOnly ? '' : 'songs.server_deleted_at IS NULL AND '}
        $_searchableSongSql
        AND (
          NOT $_songSearchTextCurrentSql
          OR (${List<String>.filled(tokens.length, 't.search_text GLOB ?').join(' AND ')})
        )
      ''',
      variables: <Variable<Object>>[
        for (final token in tokens)
          Variable<String>(songSearchSubsequenceGlob(token)),
      ],
      readsFrom: {songsTable, songSearchTextTable},
    ).get();

    final stale = <({String songId, String source, String searchText})>[];
    final matches = <_SongSearchMatch>[];
    for (final row in rows) {
      final title = row.read<String>('title');
      var searchText = row.readNullable<String>('search_text');
      if (searchText == null) {
        final artistName = row.readNullable<String>('artist_name');
        final albumName = row.readNullable<String>('album_name');
        searchText = buildSongSearchText(
          title: title,
          artistName: artistName,
          albumName: albumName,
        );
        stale.add((
          songId: row.read<String>('id'),
          source: _songSearchSource(title, artistName, albumName),
          searchText: searchText,
        ));
      }
      final score = _songSearchScore(searchText, normalizedQuery, tokens);
      if (score == null) continue;
      matches.add(
        _SongSearchMatch(
          songId: row.read<String>('id'),
          title: title,
          score: score,
        ),
      );
    }
    matches.sort((a, b) {
      final scoreDiff = a.score.compareTo(b.score);
      if (scoreDiff != 0) return scoreDiff;
      final titleDiff = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      if (titleDiff != 0) return titleDiff;
      return a.songId.compareTo(b.songId);
    });
    final results = await getSongsByIds(
      matches.take(limit).map((match) => match.songId),
    );
    if (_songSearchIndexRefresh == null) {
      // Defer the full stale-row scan until the caller has the results.
      // Searches can reuse legacy text while the shared refresh re-keys it.
      unawaited(
        Future<void>(() async {
          try {
            if (_songSearchIndexRefresh == null &&
                (stale.isNotEmpty || await _hasStaleSongSearchIndexRows())) {
              await scheduleSongSearchIndexRefresh();
            }
          } on Object catch (error) {
            AppLogger.debug('Song search index stale check skipped: $error');
          }
        }),
      );
    }
    return results;
  }

  Future<int>? _songSearchIndexRefresh;

  Future<bool> _hasStaleSongSearchIndexRows() async =>
      await customSelect(
        'SELECT 1 FROM songs '
        'LEFT JOIN song_search_text t ON t.song_id = songs.id '
        'WHERE t.source IS NOT ($_songSearchSourceSql) OR t.match_title IS NULL '
        'LIMIT 1',
        readsFrom: {songsTable, songSearchTextTable},
      ).getSingleOrNull() !=
      null;

  /// Starts [refreshSongSearchIndex] unless one is already running, and
  /// returns the in-flight refresh.
  Future<int> scheduleSongSearchIndexRefresh() {
    return _songSearchIndexRefresh ??= refreshSongSearchIndex()
        .catchError((Object error) {
          AppLogger.debug('Song search index refresh skipped: $error');
          return 0;
        })
        .whenComplete(() => _songSearchIndexRefresh = null);
  }

  /// Normalizes and stores every missing or stale local-search index row, in
  /// bounded transactions. Returns the number of rows written. Rows written
  /// before schema 87 lack track-matching keys and count as stale.
  ///
  /// Raw statements are used so the derived index never wakes song watchers,
  /// and normalization runs off the UI isolate.
  Future<int> refreshSongSearchIndex({int batchSize = 2000}) async {
    var written = 0;
    while (true) {
      final rows = await customSelect(
        '''
        SELECT songs.id AS id, songs.title AS title,
          songs.artist_name AS artist_name, songs.album_name AS album_name
        FROM songs
        LEFT JOIN song_search_text t ON t.song_id = songs.id
        WHERE t.source IS NOT ($_songSearchSourceSql) OR t.match_title IS NULL
        LIMIT ?
        ''',
        variables: <Variable<Object>>[Variable<int>(batchSize)],
        readsFrom: {songsTable, songSearchTextTable},
      ).get();
      if (rows.isEmpty) break;
      final raw = <(String, String, String?, String?)>[
        for (final row in rows)
          (
            row.read<String>('id'),
            row.read<String>('title'),
            row.readNullable<String>('artist_name'),
            row.readNullable<String>('album_name'),
          ),
      ];
      final entries = await Isolate.run(
        () => raw.map(songSearchIndexEntry).toList(growable: false),
      );
      final stored = await _storeSongSearchText(entries);
      if (!stored) break;
      written += rows.length;
      if (rows.length < batchSize) break;
    }
    await customStatement(
      'DELETE FROM song_search_text '
      'WHERE song_id NOT IN (SELECT id FROM songs)',
    );
    return written;
  }

  Future<bool> _storeSongSearchText(List<SongSearchIndexEntry> entries) async {
    // One multi-row statement per chunk keeps a full rebuild to about a
    // hundred round trips to the database isolate.
    const chunkSize = 300;
    for (final chunk in chunked(entries, chunkSize)) {
      try {
        await customStatement(
          'INSERT INTO song_search_text(song_id, source, search_text, '
          'match_title, match_artist, match_album) VALUES '
          '${List<String>.filled(chunk.length, '(?, ?, ?, ?, ?, ?)').join(', ')} '
          'ON CONFLICT(song_id) DO UPDATE SET '
          'source = excluded.source, search_text = excluded.search_text, '
          'match_title = excluded.match_title, '
          'match_artist = excluded.match_artist, '
          'match_album = excluded.match_album',
          <Object?>[
            for (final entry in chunk) ...<Object?>[
              entry.songId,
              entry.source,
              entry.searchText,
              entry.matchTitle,
              entry.matchArtist,
              entry.matchAlbum,
            ],
          ],
        );
      } on Object catch (error) {
        // The index is derived data; a failed write only means the next
        // search normalizes these rows again.
        AppLogger.debug('Song search index write skipped: $error');
        return false;
      }
    }
    return true;
  }

  Future<void> _awaitSongSearchIndexRefresh() async {
    var refresh = _songSearchIndexRefresh;
    if (refresh == null && await _hasStaleSongSearchIndexRows()) {
      refresh = scheduleSongSearchIndexRefresh();
    }
    if (refresh == null) return;
    // The refresh keeps running; stale rows remain safe match candidates.
    await refresh.timeout(const Duration(seconds: 2), onTimeout: () => 0);
  }

  /// Songs that could match any of [tracks] (title and artist) under
  /// `LocalTrackMatchSnapshot` rules: every song whose title key equals a
  /// track's, and every song whose artist key could satisfy its artist
  /// fallback (equal, containing or contained, or sharing a word). A snapshot
  /// built from these makes the same matches as one built from the whole
  /// library, without loading every song. When rows are stale or a refresh
  /// is running, waits at most two seconds for the shared refresh. Fresh
  /// indexes require no refresh writes; a slow refresh continues in the
  /// background while matching falls back to the safe stale candidates.
  /// Rows changed concurrently, or left stale by a failed index write, remain
  /// candidates so the derived index cannot hide a possible match.
  ///
  /// The artist fallback depends only on the artist key, so it is tested
  /// once per distinct key (a few thousand) in an isolate instead of once per
  /// song, and the matching songs are read through the title and artist indexes.
  Future<List<SongsTableData>> getTrackMatchCandidates(
    Iterable<({String title, String artist})> tracks,
  ) async {
    await _awaitSongSearchIndexRefresh();
    final (:titleKeys, :artistKeys, :artistTokens) = _trackMatchKeys(tracks);
    var matchedArtists = <String>[];
    if (artistKeys.isNotEmpty) {
      final keys = await customSelect(
        'SELECT DISTINCT match_artist AS a FROM song_search_text '
        "WHERE match_artist <> ''",
        readsFrom: {songSearchTextTable},
      ).map((row) => row.read<String>('a')).get();
      matchedArtists = await _matchingTrackArtistKeysInIsolate(
        keys,
        artistKeys,
        artistTokens,
      );
    }
    final rows = await customSelect(
      '''
      SELECT songs.*,
        t.source IS NOT ($_songSearchSourceSql) OR t.match_title IS NULL
          AS index_stale
      FROM songs
      LEFT JOIN song_search_text t ON t.song_id = songs.id
      WHERE songs.server_deleted_at IS NULL AND songs.is_provisional = 0
        AND songs.id IN (
          SELECT song_id FROM song_search_text
          WHERE match_title IN (SELECT value FROM json_each(?))
          UNION
          SELECT song_id FROM song_search_text
          WHERE match_artist IN (SELECT value FROM json_each(?))
          UNION
          SELECT songs.id FROM songs
          LEFT JOIN song_search_text t ON t.song_id = songs.id
          WHERE t.source IS NOT ($_songSearchSourceSql)
            OR t.match_title IS NULL
        )
      ''',
      variables: [
        Variable<String>(jsonEncode(titleKeys.toList(growable: false))),
        Variable<String>(jsonEncode(matchedArtists)),
      ],
      readsFrom: {songsTable, songSearchTextTable},
    ).get();
    if (rows.any((row) => row.read<bool>('index_stale'))) {
      unawaited(scheduleSongSearchIndexRefresh());
    }
    return await _mapSongRowsInChunks(rows);
  }

  /// Maps raw song rows in order, yielding between chunks so a large result
  /// set never blocks the UI isolate in one pass.
  Future<List<SongsTableData>> _mapSongRowsInChunks(List<QueryRow> rows) async {
    final songs = <SongsTableData>[];
    for (var index = 0; index < rows.length; index++) {
      songs.add(songsTable.map(rows[index].data));
      if ((index + 1) % kLocalTrackMatcherSnapshotYieldChunkSize == 0 &&
          index + 1 < rows.length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return songs;
  }

  /// [getTrackMatchCandidates] as one scan that tests every song's artist
  /// key in SQL; the reference its indexed lookup must agree with.
  @visibleForTesting
  Future<List<SongsTableData>> debugTrackMatchCandidatesByFullScan(
    Iterable<({String title, String artist})> tracks,
  ) async {
    await _awaitSongSearchIndexRefresh();
    final (:titleKeys, :artistKeys, :artistTokens) = _trackMatchKeys(tracks);
    final conditions = <String>[
      't.source IS NOT ($_songSearchSourceSql)',
      't.match_title IS NULL',
    ];
    final variables = <Variable<Object>>[];
    for (var offset = 0; offset < titleKeys.length; offset += 400) {
      final chunk = titleKeys.skip(offset).take(400).toList(growable: false);
      conditions.add(
        't.match_title IN (${List<String>.filled(chunk.length, '?').join(', ')})',
      );
      variables.addAll(chunk.map(Variable<String>.new));
    }
    for (final artist in artistKeys) {
      conditions.add(
        '(t.match_artist = ? OR (length(t.match_artist) >= 2 AND ? >= 2 '
        'AND (instr(t.match_artist, ?) > 0 OR instr(?, t.match_artist) > 0)))',
      );
      variables
        ..add(Variable<String>(artist))
        ..add(Variable<int>(artist.runes.length))
        ..add(Variable<String>(artist))
        ..add(Variable<String>(artist));
    }
    for (final token in artistTokens) {
      conditions.add("instr(' ' || t.match_artist || ' ', ?) > 0");
      variables.add(Variable<String>(' $token '));
    }
    final rows = await customSelect(
      '''
      SELECT songs.*
      FROM songs
      LEFT JOIN song_search_text t ON t.song_id = songs.id
      WHERE songs.server_deleted_at IS NULL AND songs.is_provisional = 0
        AND (${conditions.join(' OR ')})
      ''',
      variables: variables,
      readsFrom: {songsTable, songSearchTextTable},
    ).get();
    return rows.map((row) => songsTable.map(row.data)).toList();
  }

  // Keep the isolate closure out of the DAO method's captured database scope.
  static Future<List<String>> _matchingTrackArtistKeysInIsolate(
    List<String> keys,
    Set<String> artistKeys,
    Set<String> artistTokens,
  ) => Isolate.run(
    () => _matchingTrackArtistKeys(keys, artistKeys, artistTokens),
  );

  static List<String> _matchingTrackArtistKeys(
    List<String> keys,
    Set<String> artistKeys,
    Set<String> artistTokens,
  ) {
    final matchedArtists = <String>[];
    for (final key in keys) {
      if (artistKeys.any(
            (artist) =>
                key == artist ||
                (key.runes.length >= 2 &&
                    artist.runes.length >= 2 &&
                    (key.contains(artist) || artist.contains(key))),
          ) ||
          key.split(' ').any(artistTokens.contains)) {
        matchedArtists.add(key);
      }
    }
    return matchedArtists;
  }

  static ({
    Set<String> titleKeys,
    Set<String> artistKeys,
    Set<String> artistTokens,
  })
  _trackMatchKeys(Iterable<({String title, String artist})> tracks) {
    final titleKeys = <String>{};
    final artistKeys = <String>{};
    for (final track in tracks) {
      final title = normalizeMetadata(track.title);
      if (title.isNotEmpty) titleKeys.add(title);
      final artist = normalizeMetadata(track.artist);
      if (artist.isNotEmpty) artistKeys.add(artist);
    }
    return (
      titleKeys: titleKeys,
      artistKeys: artistKeys,
      artistTokens: <String>{
        for (final artist in artistKeys)
          ...artist.split(' ').where((token) => token.runes.length > 1),
      },
    );
  }

  static const String _songSearchFieldsSql =
      "songs.title || char(31) || ifnull(songs.artist_name, '') || char(31) "
      "|| ifnull(songs.album_name, '')";

  /// The current `source` of a song's index row: its raw fields plus
  /// `metadataKeyVersion`, so rows whose match keys an older normalizer
  /// wrote are stale.
  static const String _songSearchSourceSql =
      "$_songSearchFieldsSql || char(31) || '$metadataKeyVersion'";

  /// Whether `t.search_text` is usable: it depends on the raw fields,
  /// so any key version (including pre-versioned rows) qualifies. A version
  /// bump must not re-normalize every song on the UI isolate per keystroke.
  /// Background refreshes still re-key these rows for search and matching;
  /// until then, searches retain the older folding behavior.
  static const String _songSearchTextCurrentSql =
      '(ifnull(t.source = ($_songSearchSourceSql), 0) OR '
      'ifnull(substr(t.source || char(31), 1, '
      'length($_songSearchFieldsSql) + 1) = '
      '($_songSearchFieldsSql) || char(31), 0))';

  static String _songSearchSource(
    String title,
    String? artistName,
    String? albumName,
  ) =>
      '$title\u001f${artistName ?? ''}\u001f${albumName ?? ''}'
      '\u001f$metadataKeyVersion';

  int? _songSearchScore(String searchText, String query, List<String> tokens) {
    final fields = searchText.split(songSearchFieldSeparator);
    final title = fields.isNotEmpty ? fields[0] : '';
    final artist = fields.length > 1 ? fields[1] : '';
    final album = fields.length > 2 ? fields[2] : '';
    final combined = <String>[
      title,
      artist,
      album,
    ].where((field) => field.isNotEmpty).join(' ');

    int? best;
    void addScore(String field, int weight) {
      final score = _searchFieldScore(field, query, tokens);
      if (score == null) return;
      final weighted = weight + score;
      if (best == null || weighted < best!) best = weighted;
    }

    addScore(title, 0);
    addScore(artist, 8);
    addScore(album, 12);
    addScore(combined, 18);
    return best;
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

  /// ASCII-only normalization for SQL `LIKE` against `LOWER(title)`, which
  /// cannot fold Unicode the way the local search index does.
  String _asciiSearchText(String value) {
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
      ..where(
        (table) =>
            table.songsHydrated.equals(false) &
            table.isProvisional.equals(false) &
            table.isExternal.equals(false),
      )
      ..limit(limit < 1 ? 1 : limit);
    return query.get();
  }

  Future<List<String>> getPendingHydrationAlbumIds() async {
    final query = selectOnly(albumsTable)
      ..addColumns([albumsTable.id])
      ..where(
        albumsTable.songsHydrated.equals(false) &
            albumsTable.isProvisional.equals(false) &
            albumsTable.isExternal.equals(false),
      );
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
    final idList = ids.toSet().toList(growable: false);
    if (idList.isEmpty) {
      return const <AlbumsTableData>[];
    }

    final boundedLimit = limit.clamp(1, 500);
    final ordered = <AlbumsTableData>[];
    // Select bounded slices in caller priority order. SQL LIMIT on an IN set
    // can choose different IDs before Dart gets a chance to restore ordering.
    for (var offset = 0; offset < idList.length; offset += boundedLimit) {
      final slice = idList.skip(offset).take(boundedLimit).toList();
      final rows =
          await (select(albumsTable)..where(
                (table) =>
                    table.songsHydrated.equals(false) &
                    table.isProvisional.equals(false) &
                    table.isExternal.equals(false) &
                    table.id.isIn(slice),
              ))
              .get();
      final byId = {for (final row in rows) row.id: row};
      for (final id in slice) {
        final row = byId[id];
        if (row != null) ordered.add(row);
        if (ordered.length == boundedLimit) return ordered;
      }
    }
    return ordered;
  }

  Future<int> countPendingHydrationAlbums() async {
    final countExpression = albumsTable.id.count();
    final query = selectOnly(albumsTable)
      ..addColumns([countExpression])
      ..where(
        albumsTable.songsHydrated.equals(false) &
            albumsTable.isProvisional.equals(false) &
            albumsTable.isExternal.equals(false),
      );
    final row = await query.getSingle();
    final resolvedCount = row.read(countExpression) ?? 0;
    return resolvedCount;
  }

  /// Live variant of [countPendingHydrationAlbums] so the UI can surface the
  /// metadata backlog between sync runs.
  Stream<int> watchPendingHydrationAlbums() {
    final countExpression = albumsTable.id.count();
    final query = selectOnly(albumsTable)
      ..addColumns([countExpression])
      ..where(
        albumsTable.songsHydrated.equals(false) &
            albumsTable.isProvisional.equals(false) &
            albumsTable.isExternal.equals(false),
      );
    return query.watchSingle().map((row) => row.read(countExpression) ?? 0);
  }

  Future<void> markAlbumsPendingHydrationByIds(
    Iterable<String> albumIds,
  ) async {
    final ids = albumIds.where((id) => id.trim().isNotEmpty).toList();
    if (ids.isEmpty) {
      return;
    }
    await (update(albumsTable)..where((table) => table.id.isIn(ids))).write(
      const AlbumsTableCompanion(songsHydrated: Value(false)),
    );
  }

  Future<void> markAlbumSongsHydrated(String albumId) {
    return (update(albumsTable)..where((table) => table.id.equals(albumId)))
        .write(const AlbumsTableCompanion(songsHydrated: Value(true)));
  }

  Future<void> markAlbumsSongsHydratedByIds(Iterable<String> albumIds) async {
    final ids = albumIds.map((id) => id.trim()).where((id) => id.isNotEmpty);
    final idList = ids.toList(growable: false);
    if (idList.isEmpty) {
      return;
    }
    await (update(albumsTable)..where((table) => table.id.isIn(idList))).write(
      const AlbumsTableCompanion(songsHydrated: Value(true)),
    );
  }

  SimpleSelectStatement<$AlbumsTableTable, AlbumsTableData> _orderedAlbumsQuery(
    AlbumSortOrder sort,
  ) {
    final query = select(albumsTable)
      ..where(
        (table) =>
            table.isProvisional.equals(false) & table.isExternal.equals(false),
      );
    switch (sort) {
      case AlbumSortOrder.recentlyAdded:
        // The server's newest feed is authoritative whenever it supplied a
        // position. Rows outside that feed use only a server creation date.
        query.orderBy([
          (table) => OrderingTerm(
            expression: table.recentlyAddedRank,
            mode: OrderingMode.asc,
            nulls: NullsOrder.last,
          ),
          (table) => OrderingTerm(
            expression: table.serverCreatedAt,
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
    final sql = StringBuffer('SELECT albums.* FROM albums WHERE ');
    if (likedOnly) {
      sql.write(_likedAlbumPredicate('albums'));
    } else {
      sql.write('albums.is_provisional = 0 AND albums.is_external = 0');
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
    // Album-only queries must not declare songs: sync writes songs in many
    // small chunks, and each would re-run every visible album list.
    return customSelect(
      sql.toString(),
      variables: variables,
      readsFrom: {albumsTable},
    ).watch().map(
      (rows) =>
          rows.map((row) => albumsTable.map(row.data)).toList(growable: false),
    );
  }

  String _likedAlbumPredicate(String albumAlias) {
    // Only explicitly starred albums — liked songs have their own section.
    return '$albumAlias.starred IS NOT NULL';
  }

  Expression<bool> _searchableSongPredicate() {
    return const CustomExpression<bool>(_searchableSongSql);
  }

  static const String _searchableSongSql = '''
      (songs.is_provisional = 0 OR
       COALESCE(songs.catalog_availability, 'present') != 'pendingRebuild')
      AND
      (
        songs.is_provisional = 0
        OR EXISTS (
          SELECT 1
          FROM cached_tracks c
          WHERE c.song_id = songs.id
            AND c.download_status = 'complete'
        )
        OR EXISTS (
          SELECT 1 FROM play_queue_items q WHERE q.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1 FROM playlist_songs p WHERE p.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1 FROM play_history h WHERE h.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1 FROM download_queue d WHERE d.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1 FROM match_flow_songs m WHERE m.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1 FROM scrobble_queue s WHERE s.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1
          FROM listenbrainz_feedback_queue f
          WHERE f.song_id = songs.id
        )
        OR EXISTS (
          SELECT 1
          FROM star_sync_queue st
          WHERE st.item_type = 'song' AND st.item_id = songs.id
        )
      )
      ''';

  String _albumOrderSql(AlbumSortOrder sort, bool includeUnknownYearsLast) {
    switch (sort) {
      case AlbumSortOrder.recentlyAdded:
        return 'recently_added_rank IS NULL ASC, recently_added_rank ASC, '
            'server_created_at IS NULL ASC, server_created_at DESC, '
            'name ASC, id ASC';
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

  // The same normalization as track matching; the derived album artist
  // index stores keys in this form.
  String _normalizeMetadataLookup(String value) => normalizeMetadata(value);
}

class _SongSearchMatch {
  const new({required this.songId, required this.title, required this.score});

  final String songId;
  final String title;
  final int score;
}

/// Per-album download counts from [LibraryDao.watchAlbumDownloadSummaries].
class AlbumDownloadSummary {
  const new({
    required this.albumId,
    required this.totalTrackCount,
    required this.downloadedTrackCount,
    required this.inFlightProgress,
    required this.queued,
  });

  final String albumId;
  final int totalTrackCount;
  final int downloadedTrackCount;

  /// Sum of in-progress download fractions for tracks not yet downloaded.
  final double inFlightProgress;
  final bool queued;
}

/// One derived `song_search_text` row.
typedef SongSearchIndexEntry = ({
  String songId,
  String source,
  String searchText,
  String matchTitle,
  String matchArtist,
  String matchAlbum,
});

/// Builds the derived search and track-matching keys for a raw song
/// (id, title, artist name, album name). Top level so it can run in an
/// isolate.
SongSearchIndexEntry songSearchIndexEntry(
  (String, String, String?, String?) song,
) {
  final (id, title, artistName, albumName) = song;
  return (
    songId: id,
    source: LibraryDao._songSearchSource(title, artistName, albumName),
    searchText: buildSongSearchText(
      title: title,
      artistName: artistName,
      albumName: albumName,
    ),
    matchTitle: normalizeMetadata(title),
    matchArtist: normalizeMetadata(artistName ?? ''),
    matchAlbum: normalizeMetadata(albumName ?? ''),
  );
}

/// One derived `album_artist_index` row.
typedef AlbumArtistIndexEntry = ({
  String albumId,
  String source,
  String artistKeys,
});

/// Builds an album's artist keys from its raw artist id, artist name, and
/// credits JSON, matching the artist page's classification: the album
/// artist's id, or its normalized name when it has no id, and each credit's
/// id and normalized name. Top level so it can run in an isolate.
AlbumArtistIndexEntry albumArtistIndexEntry(
  (String, String?, String?, String) album,
) {
  final (id, artistId, artistName, artistsJson) = album;
  final keys = <String>{};
  final albumArtistId = artistId?.trim() ?? '';
  if (albumArtistId.isNotEmpty) {
    keys.add('i:$albumArtistId');
  } else {
    final name = normalizeMetadata(artistName ?? '');
    if (name.isNotEmpty) keys.add('n:$name');
  }
  for (final credit in const ArtistRefListConverter().fromSql(artistsJson)) {
    final creditId = credit.id.trim();
    if (creditId.isNotEmpty) keys.add('i:$creditId');
    final name = normalizeMetadata(credit.name);
    if (name.isNotEmpty) keys.add('n:$name');
  }
  return (
    albumId: id,
    source:
        '${artistId ?? ''}\u001f${artistName ?? ''}\u001f$artistsJson'
        '\u001f$metadataKeyVersion',
    artistKeys: keys.isEmpty ? '' : '\u001f${keys.join('\u001f')}\u001f',
  );
}
