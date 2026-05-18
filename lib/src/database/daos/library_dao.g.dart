// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_dao.dart';

// ignore_for_file: type=lint
mixin _$LibraryDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $GenresTableTable get genresTable => attachedDatabase.genresTable;
  $AlbumInfoCacheTableTable get albumInfoCacheTable =>
      attachedDatabase.albumInfoCacheTable;
  $ExternalLyricsCacheTableTable get externalLyricsCacheTable =>
      attachedDatabase.externalLyricsCacheTable;
  $CachedTracksTableTable get cachedTracksTable =>
      attachedDatabase.cachedTracksTable;
  $DownloadQueueTableTable get downloadQueueTable =>
      attachedDatabase.downloadQueueTable;
  $MatchFlowsTableTable get matchFlowsTable => attachedDatabase.matchFlowsTable;
  $MatchFlowSongsTableTable get matchFlowSongsTable =>
      attachedDatabase.matchFlowSongsTable;
  LibraryDaoManager get managers => LibraryDaoManager(this);
}

class LibraryDaoManager {
  final _$LibraryDaoMixin _db;
  LibraryDaoManager(this._db);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$GenresTableTableTableManager get genresTable =>
      $$GenresTableTableTableManager(_db.attachedDatabase, _db.genresTable);
  $$AlbumInfoCacheTableTableTableManager get albumInfoCacheTable =>
      $$AlbumInfoCacheTableTableTableManager(
        _db.attachedDatabase,
        _db.albumInfoCacheTable,
      );
  $$ExternalLyricsCacheTableTableTableManager get externalLyricsCacheTable =>
      $$ExternalLyricsCacheTableTableTableManager(
        _db.attachedDatabase,
        _db.externalLyricsCacheTable,
      );
  $$CachedTracksTableTableTableManager get cachedTracksTable =>
      $$CachedTracksTableTableTableManager(
        _db.attachedDatabase,
        _db.cachedTracksTable,
      );
  $$DownloadQueueTableTableTableManager get downloadQueueTable =>
      $$DownloadQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.downloadQueueTable,
      );
  $$MatchFlowsTableTableTableManager get matchFlowsTable =>
      $$MatchFlowsTableTableTableManager(
        _db.attachedDatabase,
        _db.matchFlowsTable,
      );
  $$MatchFlowSongsTableTableTableManager get matchFlowSongsTable =>
      $$MatchFlowSongsTableTableTableManager(
        _db.attachedDatabase,
        _db.matchFlowSongsTable,
      );
}
