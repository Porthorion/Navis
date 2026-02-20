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
}
