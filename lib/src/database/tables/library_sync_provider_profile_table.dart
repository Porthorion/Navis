import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Observed server compatibility facts. Operational state belongs elsewhere.
class LibrarySyncProviderProfileTable extends Table {
  @override
  String get tableName => 'library_sync_provider_profile';

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();
  TextColumn get providerFingerprint => text().nullable()();
  IntColumn get conditionalIndexesMode => integer().withDefault(
    const Constant(0),
  )();
  IntColumn get bulkSongSearchMode => integer().withDefault(
    const Constant(0),
  )();
  IntColumn get safePageSize => integer().withDefault(const Constant(500))();
  DateTimeColumn get observedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {serverId};
}
