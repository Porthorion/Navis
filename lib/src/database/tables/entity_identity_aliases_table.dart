import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

/// Profile-scoped identity alias for any catalog entity type.
///
/// Extends the song-only `song_identity_aliases` contract to albums and
/// artists. Legacy song aliases migrated from that table keep `serverId` null
/// so they continue resolving for every profile exactly as before; new rows
/// are always profile-scoped. Resolution reads this table first and falls
/// back to the legacy song table for compatibility.
class EntityIdentityAliasTable extends Table {
  @override
  String get tableName => 'entity_identity_aliases';

  IntColumn get id => integer().autoIncrement()();

  /// Null for legacy rows imported from `song_identity_aliases`.
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
