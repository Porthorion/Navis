import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class ScrobbleQueueTable extends Table {
  @override
  String get tableName => 'scrobble_queue';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  BoolColumn get submission => boolean()();

  DateTimeColumn get createdAt => dateTime()();

  DateTimeColumn get nextAttemptAt => dateTime()();

  IntColumn get attempts => integer().withDefault(const Constant(0))();

  DateTimeColumn get expiresAt => dateTime()();

  TextColumn get sessionKey => text()();

  TextColumn get lastError => text().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => <Set<Column<Object>>>[
    <Column<Object>>{
      songId,
      submission,
      sessionKey,
    },
  ];
}
