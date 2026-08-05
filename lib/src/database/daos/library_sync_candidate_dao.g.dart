// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_sync_candidate_dao.dart';

// ignore_for_file: type=lint
mixin _$LibrarySyncCandidateDaoMixin on DatabaseAccessor<NavisDatabase> {
  $LibrarySyncCandidateArtistsTableTable get librarySyncCandidateArtistsTable =>
      attachedDatabase.librarySyncCandidateArtistsTable;
  $LibrarySyncCandidateAlbumsTableTable get librarySyncCandidateAlbumsTable =>
      attachedDatabase.librarySyncCandidateAlbumsTable;
  $LibrarySyncCandidateSongsTableTable get librarySyncCandidateSongsTable =>
      attachedDatabase.librarySyncCandidateSongsTable;
  $ArtistsTableTable get artistsTable => attachedDatabase.artistsTable;
  $AlbumsTableTable get albumsTable => attachedDatabase.albumsTable;
  $SongsTableTable get songsTable => attachedDatabase.songsTable;
  LibrarySyncCandidateDaoManager get managers =>
      LibrarySyncCandidateDaoManager(this);
}

class LibrarySyncCandidateDaoManager {
  final _$LibrarySyncCandidateDaoMixin _db;
  LibrarySyncCandidateDaoManager(this._db);
  $$LibrarySyncCandidateArtistsTableTableTableManager
  get librarySyncCandidateArtistsTable =>
      $$LibrarySyncCandidateArtistsTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncCandidateArtistsTable,
      );
  $$LibrarySyncCandidateAlbumsTableTableTableManager
  get librarySyncCandidateAlbumsTable =>
      $$LibrarySyncCandidateAlbumsTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncCandidateAlbumsTable,
      );
  $$LibrarySyncCandidateSongsTableTableTableManager
  get librarySyncCandidateSongsTable =>
      $$LibrarySyncCandidateSongsTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncCandidateSongsTable,
      );
  $$ArtistsTableTableTableManager get artistsTable =>
      $$ArtistsTableTableTableManager(_db.attachedDatabase, _db.artistsTable);
  $$AlbumsTableTableTableManager get albumsTable =>
      $$AlbumsTableTableTableManager(_db.attachedDatabase, _db.albumsTable);
  $$SongsTableTableTableManager get songsTable =>
      $$SongsTableTableTableManager(_db.attachedDatabase, _db.songsTable);
}
