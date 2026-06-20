// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'listenbrainz_feedback_dao.dart';

// ignore_for_file: type=lint
mixin _$ListenBrainzFeedbackDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  $ListenBrainzFeedbackQueueTableTable get listenBrainzFeedbackQueueTable =>
      attachedDatabase.listenBrainzFeedbackQueueTable;
  ListenBrainzFeedbackDaoManager get managers =>
      ListenBrainzFeedbackDaoManager(this);
}

class ListenBrainzFeedbackDaoManager {
  final _$ListenBrainzFeedbackDaoMixin _db;
  ListenBrainzFeedbackDaoManager(this._db);
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
  $$ListenBrainzFeedbackQueueTableTableTableManager
  get listenBrainzFeedbackQueueTable =>
      $$ListenBrainzFeedbackQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.listenBrainzFeedbackQueueTable,
      );
}
