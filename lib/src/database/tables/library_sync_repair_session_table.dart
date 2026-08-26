import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Typed ownership of candidate lifecycle and confirmation evidence.
class LibrarySyncRepairSessionTable extends Table {
  @override
  String get tableName => 'library_sync_repair_session';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get generation => integer()();

  /// Collecting, validating, awaiting confirmation, ready, or applying.
  IntColumn get phase => integer()();
  TextColumn get deletionFingerprint => text().nullable()();
  IntColumn get deletionCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {serverId, generation};
}
