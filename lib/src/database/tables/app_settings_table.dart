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

  BoolColumn get showRadioPage => boolean().withDefault(const Constant(true))();

  BoolColumn get equalizerEnabled =>
      boolean().withDefault(const Constant(false))();

  TextColumn get equalizerBandGains => text().nullable()();

  BoolColumn get loudnessEnabled =>
      boolean().withDefault(const Constant(false))();

  RealColumn get loudnessTargetGainDb => real().nullable()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
