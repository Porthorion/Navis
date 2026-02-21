// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'scrobble_dao.dart';

// ignore_for_file: type=lint
mixin _$ScrobbleDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $ScrobbleQueueTableTable get scrobbleQueueTable =>
      attachedDatabase.scrobbleQueueTable;
  ScrobbleDaoManager get managers => ScrobbleDaoManager(this);
}

class ScrobbleDaoManager {
  final _$ScrobbleDaoMixin _db;
  ScrobbleDaoManager(this._db);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$ScrobbleQueueTableTableTableManager get scrobbleQueueTable =>
      $$ScrobbleQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.scrobbleQueueTable,
      );
}
