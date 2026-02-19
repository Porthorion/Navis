// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_queue_dao.dart';

// ignore_for_file: type=lint
mixin _$DownloadQueueDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $PlaylistsTableTable get playlistsTable => attachedDatabase.playlistsTable;
  $DownloadQueueTableTable get downloadQueueTable =>
      attachedDatabase.downloadQueueTable;
  DownloadQueueDaoManager get managers => DownloadQueueDaoManager(this);
}

class DownloadQueueDaoManager {
  final _$DownloadQueueDaoMixin _db;
  DownloadQueueDaoManager(this._db);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$PlaylistsTableTableTableManager get playlistsTable =>
      $$PlaylistsTableTableTableManager(
        _db.attachedDatabase,
        _db.playlistsTable,
      );
  $$DownloadQueueTableTableTableManager get downloadQueueTable =>
      $$DownloadQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.downloadQueueTable,
      );
}
