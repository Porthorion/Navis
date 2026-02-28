// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'star_sync_dao.dart';

// ignore_for_file: type=lint
mixin _$StarSyncDaoMixin on DatabaseAccessor<NavisDatabase> {
  $StarSyncQueueTableTable get starSyncQueueTable =>
      attachedDatabase.starSyncQueueTable;
  StarSyncDaoManager get managers => StarSyncDaoManager(this);
}

class StarSyncDaoManager {
  final _$StarSyncDaoMixin _db;
  StarSyncDaoManager(this._db);
  $$StarSyncQueueTableTableTableManager get starSyncQueueTable =>
      $$StarSyncQueueTableTableTableManager(
        _db.attachedDatabase,
        _db.starSyncQueueTable,
      );
}
