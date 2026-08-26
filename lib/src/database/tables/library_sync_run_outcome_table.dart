import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/library_sync_run_attempt_table.dart';
import 'package:navis/src/database/tables/library_sync_run_request_table.dart';

/// Redacted terminal history for one request. It holds aggregate evidence only.
class LibrarySyncRunOutcomeTable extends Table {
  @override
  String get tableName => 'library_sync_run_outcome';

  IntColumn get id => integer().autoIncrement()();
  IntColumn get requestId => integer().references(
    LibrarySyncRunRequestTable,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get attemptId => integer().nullable().references(
    LibrarySyncRunAttemptTable,
    #id,
    onDelete: KeyAction.setNull,
  )();
  IntColumn get outcomeKind => integer()();
  IntColumn get safeReason => integer()();
  IntColumn get requestCount => integer().withDefault(const Constant(0))();
  IntColumn get byteCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get completedAt => dateTime()();
}
