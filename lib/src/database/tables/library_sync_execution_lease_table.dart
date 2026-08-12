import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Cross-engine ownership for broad library sync execution.
///
/// WorkManager uniqueness cannot serialize a headless Flutter engine with a
/// foreground Navis process. This row is deliberately server-scoped and
/// contains only opaque ownership data.
class LibrarySyncExecutionLeaseTable extends Table {
  @override
  String get tableName => 'library_sync_execution_lease';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get ownerToken => text()();

  TextColumn get ownerKind => text()();

  DateTimeColumn get startedAt => dateTime()();

  DateTimeColumn get heartbeatAt => dateTime()();

  DateTimeColumn get expiresAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {serverId};
}
