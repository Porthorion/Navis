import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/library_sync_run_request_table.dart';

/// One execution attempt for a durable sync request.
class LibrarySyncRunAttemptTable extends Table {
  @override
  String get tableName => 'library_sync_run_attempt';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get requestId => integer().references(
    LibrarySyncRunRequestTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  /// 0 running, 1 recovered after interruption, 2 terminal.
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get ownerKind => integer().withDefault(const Constant(0))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get completedAt => dateTime().nullable()();

  /// Bounded versioned diagnostics; no target identifiers or response payloads.
  TextColumn get telemetryJson => text().nullable()();
}
