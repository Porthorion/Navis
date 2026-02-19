import 'package:drift/drift.dart';

class GenresTable extends Table {
  @override
  String get tableName => 'genres';

  TextColumn get name => text()();

  IntColumn get songCount => integer().nullable()();

  IntColumn get albumCount => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {name};
}
