import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Safe, aggregate evidence for catalog and starred-state mutations.
///
/// The ledger deliberately stores no server IDs, names, URLs, paths, or
/// credentials. Each entry is inserted in the same database transaction as
/// the operation it describes, so an observed destructive change always has a
/// durable cause and before/after count record.
class LibrarySyncOperationLedgerTable extends Table {
  @override
  String get tableName => 'library_sync_operation_ledger';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get operation => text()();

  TextColumn get reason => text()();

  TextColumn get detailsJson => text()();

  DateTimeColumn get occurredAt => dateTime()();
}
