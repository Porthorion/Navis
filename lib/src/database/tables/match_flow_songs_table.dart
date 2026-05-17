import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/match_flows_table.dart';

class MatchFlowSongsTable extends Table {
  @override
  String get tableName => 'match_flow_songs';

  TextColumn get flowId => text().references(
    MatchFlowsTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get songId => text()();

  IntColumn get sortOrder => integer()();

  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {flowId, songId};
}
