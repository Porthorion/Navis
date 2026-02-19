import 'package:drift/drift.dart';

class ArtistsTable extends Table {
  @override
  String get tableName => 'artists';

  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get albumCount => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
