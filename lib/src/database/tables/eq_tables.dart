import 'package:drift/drift.dart';

class EqPresetsTable extends Table {
  @override
  String get tableName => 'eq_presets';

  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get normalizedName => text().unique()();
  TextColumn get presetJson => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class EqStateTable extends Table {
  @override
  String get tableName => 'eq_state';

  IntColumn get id => integer().withDefault(const Constant(1))();
  TextColumn get configurationJson => text().nullable()();
  TextColumn get selectedPresetId => text().nullable()();
  TextColumn get originPresetId => text().nullable()();
  TextColumn get workspacesJson => text().nullable()();
  BoolColumn get legacyResetNotice =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
