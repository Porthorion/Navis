import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class CachedTracksTable extends Table {
  @override
  String get tableName => 'cached_tracks';

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  TextColumn get filePath => text()();

  IntColumn get fileSize => integer()();

  TextColumn get format => text()();

  IntColumn get bitRate => integer().nullable()();

  DateTimeColumn get lastAccessedAt => dateTime()();

  TextColumn get cacheType => textEnum<CacheType>()();

  TextColumn get downloadStatus => textEnum<DownloadStatus>()();

  @override
  Set<Column<Object>> get primaryKey => {songId};
}
