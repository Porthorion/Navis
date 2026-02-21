// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_settings_dao.dart';

// ignore_for_file: type=lint
mixin _$AppSettingsDaoMixin on DatabaseAccessor<NavisDatabase> {
  $AppSettingsTableTable get appSettingsTable =>
      attachedDatabase.appSettingsTable;
  AppSettingsDaoManager get managers => AppSettingsDaoManager(this);
}

class AppSettingsDaoManager {
  final _$AppSettingsDaoMixin _db;
  AppSettingsDaoManager(this._db);
  $$AppSettingsTableTableTableManager get appSettingsTable =>
      $$AppSettingsTableTableTableManager(
        _db.attachedDatabase,
        _db.appSettingsTable,
      );
}
