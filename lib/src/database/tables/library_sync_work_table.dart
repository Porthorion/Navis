import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/server_config_table.dart';

class LibrarySyncWorkTable extends Table {
  @override
  String get tableName => 'library_sync_work';

  IntColumn get id => integer().autoIncrement()();

  IntColumn get serverId => integer().references(
    ServerConfigTable,
    #id,
    onDelete: KeyAction.cascade,
  )();

  TextColumn get kind => text()();

  TextColumn get entityId => text().withDefault(const Constant(''))();

  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// `interactive` for user-opened entity hydration; otherwise `background`.
  TextColumn get workClass =>
      text().withDefault(const Constant('background'))();

  TextColumn get status => text().withDefault(const Constant('queued'))();

  TextColumn get checkpointJson => text().nullable()();

  IntColumn get attemptCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get notBefore => dateTime().nullable()();

  TextColumn get lastErrorType => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {serverId, kind, entityId},
  ];
}
