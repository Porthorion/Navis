// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'play_queue_dao.dart';

// ignore_for_file: type=lint
mixin _$PlayQueueDaoMixin on DatabaseAccessor<NavisDatabase> {
  $PlayQueueTableTable get playQueueTable => attachedDatabase.playQueueTable;
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $PlayQueueItemsTableTable get playQueueItemsTable =>
      attachedDatabase.playQueueItemsTable;
  PlayQueueDaoManager get managers => PlayQueueDaoManager(this);
}

class PlayQueueDaoManager {
  final _$PlayQueueDaoMixin _db;
  PlayQueueDaoManager(this._db);
  $$PlayQueueTableTableTableManager get playQueueTable =>
      $$PlayQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.playQueueTable,
      );
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$PlayQueueItemsTableTableTableManager get playQueueItemsTable =>
      $$PlayQueueItemsTableTableTableManager(
        _db.attachedDatabase,
        _db.playQueueItemsTable,
      );
}
