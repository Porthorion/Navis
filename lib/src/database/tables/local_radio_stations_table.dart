import 'package:drift/drift.dart';

class LocalRadioStationsTable extends Table {
  @override
  String get tableName => 'local_radio_stations';

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get streamUrl => text()();

  TextColumn get homePageUrl => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
