// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'server_dao.dart';

// ignore_for_file: type=lint
mixin _$ServerDaoMixin on DatabaseAccessor<NavisDatabase> {
  $ServerConfigTableTable get serverConfigTable =>
      attachedDatabase.serverConfigTable;
  ServerDaoManager get managers => ServerDaoManager(this);
}

class ServerDaoManager {
  final _$ServerDaoMixin _db;
  ServerDaoManager(this._db);
  $$ServerConfigTableTableTableManager get serverConfigTable =>
      $$ServerConfigTableTableTableManager(
        _db.attachedDatabase,
        _db.serverConfigTable,
      );
}
