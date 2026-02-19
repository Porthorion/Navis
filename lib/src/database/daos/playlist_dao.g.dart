// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist_dao.dart';

// ignore_for_file: type=lint
mixin _$PlaylistDaoMixin on DatabaseAccessor<NavisDatabase> {
  $PlaylistsTableTable get playlistsTable => attachedDatabase.playlistsTable;
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $PlaylistSongsTableTable get playlistSongsTable =>
      attachedDatabase.playlistSongsTable;
  PlaylistDaoManager get managers => PlaylistDaoManager(this);
}

class PlaylistDaoManager {
  final _$PlaylistDaoMixin _db;
  PlaylistDaoManager(this._db);
  $$PlaylistsTableTableTableManager get playlistsTable =>
      $$PlaylistsTableTableTableManager(
        _db.attachedDatabase,
        _db.playlistsTable,
      );
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$PlaylistSongsTableTableTableManager get playlistSongsTable =>
      $$PlaylistSongsTableTableTableManager(
        _db.attachedDatabase,
        _db.playlistSongsTable,
      );
}
