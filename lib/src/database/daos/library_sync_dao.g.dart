// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'library_sync_dao.dart';

// ignore_for_file: type=lint
mixin _$LibrarySyncDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ServerConfigTableTable get serverConfigTable =>
      attachedDatabase.serverConfigTable;
  $LibrarySyncStateTableTable get librarySyncStateTable =>
      attachedDatabase.librarySyncStateTable;
  $LibrarySyncWorkTableTable get librarySyncWorkTable =>
      attachedDatabase.librarySyncWorkTable;
  $LibrarySyncLocalMutationsTableTable get librarySyncLocalMutationsTable =>
      attachedDatabase.librarySyncLocalMutationsTable;
  $StarredAbsenceCandidatesTableTable get starredAbsenceCandidatesTable =>
      attachedDatabase.starredAbsenceCandidatesTable;
  LibrarySyncDaoManager get managers => LibrarySyncDaoManager(this);
}

class LibrarySyncDaoManager {
  final _$LibrarySyncDaoMixin _db;
  LibrarySyncDaoManager(this._db);
  $$ServerConfigTableTableTableManager get serverConfigTable =>
      $$ServerConfigTableTableTableManager(
        _db.attachedDatabase,
        _db.serverConfigTable,
      );
  $$LibrarySyncStateTableTableTableManager get librarySyncStateTable =>
      $$LibrarySyncStateTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncStateTable,
      );
  $$LibrarySyncWorkTableTableTableManager get librarySyncWorkTable =>
      $$LibrarySyncWorkTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncWorkTable,
      );
  $$LibrarySyncLocalMutationsTableTableTableManager
  get librarySyncLocalMutationsTable =>
      $$LibrarySyncLocalMutationsTableTableTableManager(
        _db.attachedDatabase,
        _db.librarySyncLocalMutationsTable,
      );
  $$StarredAbsenceCandidatesTableTableTableManager
  get starredAbsenceCandidatesTable =>
      $$StarredAbsenceCandidatesTableTableTableManager(
        _db.attachedDatabase,
        _db.starredAbsenceCandidatesTable,
      );
}
