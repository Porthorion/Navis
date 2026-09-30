// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_dao.dart';

// ignore_for_file: type=lint
mixin _$LibraryDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $SongSearchTextTableTable get songSearchTextTable =>
      attachedDatabase.songSearchTextTable;
  $AlbumArtistIndexTableTable get albumArtistIndexTable =>
      attachedDatabase.albumArtistIndexTable;
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
  $LibrarySyncLocalMutationsTableTable get librarySyncLocalMutationsTable =>
      attachedDatabase.librarySyncLocalMutationsTable;
  $StarSyncQueueTableTable get starSyncQueueTable =>
      attachedDatabase.starSyncQueueTable;
  $PlayHistoryTableTable get playHistoryTable =>
      attachedDatabase.playHistoryTable;
  $PlayQueueTableTable get playQueueTable => attachedDatabase.playQueueTable;
  $PlayQueueItemsTableTable get playQueueItemsTable =>
      attachedDatabase.playQueueItemsTable;
  $PlaylistsTableTable get playlistsTable => attachedDatabase.playlistsTable;
  $PlaylistSongsTableTable get playlistSongsTable =>
      attachedDatabase.playlistSongsTable;
  $ScrobbleQueueTableTable get scrobbleQueueTable =>
      attachedDatabase.scrobbleQueueTable;
  $ListenBrainzFeedbackQueueTableTable get listenBrainzFeedbackQueueTable =>
      attachedDatabase.listenBrainzFeedbackQueueTable;
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
  $$SongSearchTextTableTableTableManager get songSearchTextTable =>
      $$SongSearchTextTableTableTableManager(
        _db.attachedDatabase,
        _db.songSearchTextTable,
      );
  $$AlbumArtistIndexTableTableTableManager get albumArtistIndexTable =>
      $$AlbumArtistIndexTableTableTableManager(
        _db.attachedDatabase,
        _db.albumArtistIndexTable,
      );
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
  $$LibrarySyncLocalMutationsTableTableTableManager
  get librarySyncLocalMutationsTable =>
      $$LibrarySyncLocalMutationsTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncLocalMutationsTable,
      );
  $$StarSyncQueueTableTableTableManager get starSyncQueueTable =>
      $$StarSyncQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.starSyncQueueTable,
      );
  $$PlayHistoryTableTableTableManager get playHistoryTable =>
      $$PlayHistoryTableTableTableManager(
        _db.attachedDatabase,
        _db.playHistoryTable,
      );
  $$PlayQueueTableTableTableManager get playQueueTable =>
      $$PlayQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.playQueueTable,
      );
  $$PlayQueueItemsTableTableTableManager get playQueueItemsTable =>
      $$PlayQueueItemsTableTableTableManager(
        _db.attachedDatabase,
        _db.playQueueItemsTable,
      );
  $$PlaylistsTableTableTableManager get playlistsTable =>
      $$PlaylistsTableTableTableManager(
        _db.attachedDatabase,
        _db.playlistsTable,
      );
  $$PlaylistSongsTableTableTableManager get playlistSongsTable =>
      $$PlaylistSongsTableTableTableManager(
        _db.attachedDatabase,
        _db.playlistSongsTable,
      );
  $$ScrobbleQueueTableTableTableManager get scrobbleQueueTable =>
      $$ScrobbleQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.scrobbleQueueTable,
      );
  $$ListenBrainzFeedbackQueueTableTableTableManager
  get listenBrainzFeedbackQueueTable =>
      $$ListenBrainzFeedbackQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.listenBrainzFeedbackQueueTable,
      );
}
