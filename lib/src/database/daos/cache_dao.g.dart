// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cache_dao.dart';

// ignore_for_file: type=lint
mixin _$CacheDaoMixin on DatabaseAccessor<NavisDatabase> {
  $CachedTracksTableTable get cachedTracksTable =>
      attachedDatabase.cachedTracksTable;
  $ListenBrainzWeeklyCacheTableTable get listenBrainzWeeklyCacheTable =>
      attachedDatabase.listenBrainzWeeklyCacheTable;
  CacheDaoManager get managers => CacheDaoManager(this);
}

class CacheDaoManager {
  final _$CacheDaoMixin _db;
  CacheDaoManager(this._db);
  $$CachedTracksTableTableTableManager get cachedTracksTable =>
      $$CachedTracksTableTableTableManager(
        _db.attachedDatabase,
        _db.cachedTracksTable,
      );
  $$ListenBrainzWeeklyCacheTableTableTableManager
  get listenBrainzWeeklyCacheTable =>
      $$ListenBrainzWeeklyCacheTableTableTableManager(
        _db.attachedDatabase,
        _db.listenBrainzWeeklyCacheTable,
      );
}
