// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'eq_dao.dart';

// ignore_for_file: type=lint
mixin _$EqDaoMixin on DatabaseAccessor<NavisDatabase> {
  $EqPresetsTableTable get eqPresetsTable => attachedDatabase.eqPresetsTable;
  $EqStateTableTable get eqStateTable => attachedDatabase.eqStateTable;
  EqDaoManager get managers => EqDaoManager(this);
}

class EqDaoManager {
  final _$EqDaoMixin _db;
  EqDaoManager(this._db);
  $$EqPresetsTableTableTableManager get eqPresetsTable =>
      $$EqPresetsTableTableTableManager(
        _db.attachedDatabase,
        _db.eqPresetsTable,
      );
  $$EqStateTableTableTableManager get eqStateTable =>
      $$EqStateTableTableTableManager(_db.attachedDatabase, _db.eqStateTable);
}
