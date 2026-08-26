import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Immutable durable contracts accepted by the sync scheduler.
///
/// Integer enum fields deliberately keep the database control protocol typed;
/// display strings and exception text are never used to resume work.
class LibrarySyncRunRequestTable extends Table {
  @override
  String get tableName => 'library_sync_run_request';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  IntColumn get contractVersion => integer()();
  IntColumn get origin => integer()();
  IntColumn get intent => integer()();
  IntColumn get targetKind => integer()();

  /// Stored only while a request is active; terminal diagnostics never expose
  /// this value.
  TextColumn get targetKey => text().withDefault(const Constant(''))();

  IntColumn get networkGrant => integer()();
  IntColumn get planKind => integer()();
  IntColumn get priority => integer()();
  TextColumn get coalescingKey => text()();
  IntColumn get status => integer().withDefault(const Constant(0))();
  IntColumn get resumedFromRequestId => integer().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
