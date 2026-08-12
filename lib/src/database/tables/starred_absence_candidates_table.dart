import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Server-starred rows that were absent from one otherwise successful snapshot.
///
/// A second independent absence is required before synchronization clears the
/// local star. This protects offline browsing from a transient or incomplete
/// `getStarred2` response without making remote unstars permanent locally.
class StarredAbsenceCandidatesTable extends Table {
  @override
  String get tableName => 'starred_absence_candidates';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get entityType => text()();

  TextColumn get entityId => text()();

  DateTimeColumn get firstObservedAt => dateTime()();

  DateTimeColumn get lastObservedAt => dateTime()();

  IntColumn get observationCount => integer().withDefault(const Constant(1))();

  @override
  Set<Column<Object>> get primaryKey => {serverId, entityType, entityId};
}
