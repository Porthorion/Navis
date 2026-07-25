import 'package:drift/drift.dart';

class SongIdentityAliasesTable extends Table {
  @override
  String get tableName => 'song_identity_aliases';

  TextColumn get oldSongId => text()();

  TextColumn get canonicalSongId => text()();

  TextColumn get matchReason => text()();

  DateTimeColumn get matchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {oldSongId};
}
