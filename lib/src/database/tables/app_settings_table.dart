import 'package:drift/drift.dart';

class AppSettingsTable extends Table {
  @override
  String get tableName => 'app_settings';

  IntColumn get id => integer()();

  IntColumn get wifiMaxBitRate => integer().nullable()();

  TextColumn get wifiFormat => text().nullable()();

  IntColumn get cellularMaxBitRate => integer().nullable()();

  TextColumn get cellularFormat => text().nullable()();

  BoolColumn get scrobbleEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get gaplessEnabled =>
      boolean().withDefault(const Constant(true))();

  BoolColumn get skipSilenceEnabled =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
