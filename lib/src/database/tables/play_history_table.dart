import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class PlayHistoryTable extends Table {
  @override
  String get tableName => 'play_history';

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  DateTimeColumn get playedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {songId, playedAt};
}
