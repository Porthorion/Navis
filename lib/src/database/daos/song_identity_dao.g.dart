// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'song_identity_dao.dart';

// ignore_for_file: type=lint
mixin _$SongIdentityDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $SongIdentityAliasesTableTable get songIdentityAliasesTable =>
      attachedDatabase.songIdentityAliasesTable;
  $CachedTracksTableTable get cachedTracksTable =>
      attachedDatabase.cachedTracksTable;
  $DownloadQueueTableTable get downloadQueueTable =>
      attachedDatabase.downloadQueueTable;
  $PlayHistoryTableTable get playHistoryTable =>
      attachedDatabase.playHistoryTable;
  $PlayQueueTableTable get playQueueTable => attachedDatabase.playQueueTable;
  $PlayQueueItemsTableTable get playQueueItemsTable =>
      attachedDatabase.playQueueItemsTable;
  $PlaylistsTableTable get playlistsTable => attachedDatabase.playlistsTable;
  $PlaylistSongsTableTable get playlistSongsTable =>
      attachedDatabase.playlistSongsTable;
  $MatchFlowsTableTable get matchFlowsTable => attachedDatabase.matchFlowsTable;
  $MatchFlowSongsTableTable get matchFlowSongsTable =>
      attachedDatabase.matchFlowSongsTable;
  $ExternalLyricsCacheTableTable get externalLyricsCacheTable =>
      attachedDatabase.externalLyricsCacheTable;
  $ScrobbleQueueTableTable get scrobbleQueueTable =>
      attachedDatabase.scrobbleQueueTable;
  $ListenBrainzFeedbackQueueTableTable get listenBrainzFeedbackQueueTable =>
      attachedDatabase.listenBrainzFeedbackQueueTable;
  $StarSyncQueueTableTable get starSyncQueueTable =>
      attachedDatabase.starSyncQueueTable;
  $ListenBrainzWeeklyCacheTableTable get listenBrainzWeeklyCacheTable =>
      attachedDatabase.listenBrainzWeeklyCacheTable;
  SongIdentityDaoManager get managers => SongIdentityDaoManager(this);
}

class SongIdentityDaoManager {
  final _$SongIdentityDaoMixin _db;
  SongIdentityDaoManager(this._db);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$SongIdentityAliasesTableTableTableManager get songIdentityAliasesTable =>
      $$SongIdentityAliasesTableTableTableManager(
        _db.attachedDatabase,
        _db.songIdentityAliasesTable,
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
  $$ExternalLyricsCacheTableTableTableManager get externalLyricsCacheTable =>
      $$ExternalLyricsCacheTableTableTableManager(
        _db.attachedDatabase,
        _db.externalLyricsCacheTable,
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
  $$StarSyncQueueTableTableTableManager get starSyncQueueTable =>
      $$StarSyncQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.starSyncQueueTable,
      );
  $$ListenBrainzWeeklyCacheTableTableTableManager
  get listenBrainzWeeklyCacheTable =>
      $$ListenBrainzWeeklyCacheTableTableTableManager(
        _db.attachedDatabase,
        _db.listenBrainzWeeklyCacheTable,
      );
}
