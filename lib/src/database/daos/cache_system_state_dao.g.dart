// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cache_system_state_dao.dart';

// ignore_for_file: type=lint
mixin _$CacheSystemStateDaoMixin on DatabaseAccessor<NavisDatabase> {
  $CacheSystemStateTableTable get cacheSystemStateTable =>
      attachedDatabase.cacheSystemStateTable;
  CacheSystemStateDaoManager get managers => CacheSystemStateDaoManager(this);
}

class CacheSystemStateDaoManager {
  final _$CacheSystemStateDaoMixin _db;
  CacheSystemStateDaoManager(this._db);
  $$CacheSystemStateTableTableTableManager get cacheSystemStateTable =>
      $$CacheSystemStateTableTableTableManager(
        _db.attachedDatabase,
        _db.cacheSystemStateTable,
      );
}
