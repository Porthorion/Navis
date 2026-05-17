import 'package:drift/drift.dart';

class MatchFlowsTable extends Table {
  @override
  String get tableName => 'match_flows';

  TextColumn get id => text()();

  TextColumn get name => text()();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
