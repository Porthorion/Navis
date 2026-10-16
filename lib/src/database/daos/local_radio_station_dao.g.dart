// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'local_radio_station_dao.dart';

// ignore_for_file: type=lint
mixin _$LocalRadioStationDaoMixin on DatabaseAccessor<NavisDatabase> {
  $LocalRadioStationsTableTable get localRadioStationsTable =>
      attachedDatabase.localRadioStationsTable;
  LocalRadioStationDaoManager get managers => LocalRadioStationDaoManager(this);
}

class LocalRadioStationDaoManager {
  final _$LocalRadioStationDaoMixin _db;
  LocalRadioStationDaoManager(this._db);
  $$LocalRadioStationsTableTableTableManager get localRadioStationsTable =>
      $$LocalRadioStationsTableTableTableManager(
        _db.attachedDatabase,
        _db.localRadioStationsTable,
      );
}
