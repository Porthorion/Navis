// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'network_usage_dao.dart';

// ignore_for_file: type=lint
mixin _$NetworkUsageDaoMixin on DatabaseAccessor<NavisDatabase> {
  $NetworkUsageTableTable get networkUsageTable =>
      attachedDatabase.networkUsageTable;
  NetworkUsageDaoManager get managers => NetworkUsageDaoManager(this);
}

class NetworkUsageDaoManager {
  final _$NetworkUsageDaoMixin _db;
  NetworkUsageDaoManager(this._db);
  $$NetworkUsageTableTableTableManager get networkUsageTable =>
      $$NetworkUsageTableTableTableManager(
        _db.attachedDatabase,
        _db.networkUsageTable,
      );
}
