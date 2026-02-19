import 'package:drift/drift.dart';

class RecentSearchesTable extends Table {
  @override
  String get tableName => 'recent_searches';

  TextColumn get query => text()();

  DateTimeColumn get searchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {query};
}
