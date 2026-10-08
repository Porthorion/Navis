import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Identity aliases shared across profiles for songs, albums and artists.
///
/// Resolution uses the newest row for each entity type and old ID. Schema 94
/// deduplicates historical rows and enforces that key with a unique index.
class EntityIdentityAliasTable extends Table {
  @override
  String get tableName => 'entity_identity_aliases';

  IntColumn get id => integer().autoIncrement()();

  /// Null preserves cross-profile resolution, including newly recorded aliases.
  IntColumn get serverId => integer().nullable().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  /// 'song', 'album', or 'artist'.
  TextColumn get entityType => text()();

  TextColumn get oldId => text()();
  TextColumn get newId => text()();
  TextColumn get matchReason => text()();
  DateTimeColumn get matchedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {serverId, entityType, oldId},
  ];
}
