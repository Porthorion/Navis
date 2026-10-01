import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class ListenBrainzFeedbackQueueTable extends Table {
  @override
  String get tableName => 'listenbrainz_feedback_queue';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  IntColumn get score => integer()();

  TextColumn get recordingMbid => text().nullable()();

  TextColumn get title => text()();

  TextColumn get artist => text()();

  TextColumn get album => text().nullable()();

  IntColumn get attempts => integer().withDefault(const Constant(0))();

  DateTimeColumn get queuedAt => dateTime()();

  DateTimeColumn get nextAttemptAt => dateTime()();

  TextColumn get lastError => text().nullable()();

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {songId},
  ];
}
