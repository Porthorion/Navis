import 'package:drift/drift.dart';

class ServerConfigTable extends Table {
  @override
  String get tableName => 'server_config';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get name => text().nullable()();

  TextColumn get url => text()();

  TextColumn get username => text()();

  TextColumn get apiVersion => text()();

  TextColumn get capabilities => text().nullable()();

  DateTimeColumn get lastSynced => dateTime().nullable()();

  DateTimeColumn get lastFullSynced => dateTime().nullable()();

  /// Whether this retained server profile currently has usable credentials.
  ///
  /// The row itself survives a keep-data sign-out so its sync state remains
  /// attached to the committed local catalog.
  BoolColumn get isAuthenticated =>
      boolean().withDefault(const Constant(true))();
}
