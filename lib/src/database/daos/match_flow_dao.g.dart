// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'match_flow_dao.dart';

// ignore_for_file: type=lint
mixin _$MatchFlowDaoMixin on DatabaseAccessor<NavisDatabase> {
  $MatchFlowsTableTable get matchFlowsTable => attachedDatabase.matchFlowsTable;
  $MatchFlowSongsTableTable get matchFlowSongsTable =>
      attachedDatabase.matchFlowSongsTable;
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  MatchFlowDaoManager get managers => MatchFlowDaoManager(this);
}

class MatchFlowDaoManager {
  final _$MatchFlowDaoMixin _db;
  MatchFlowDaoManager(this._db);
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
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
}
