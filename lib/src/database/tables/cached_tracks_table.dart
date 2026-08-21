import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

class CachedTracksTable extends Table {
  @override
  String get tableName => 'cached_tracks';

  /// Song ID from the Subsonic server.
  ///
  /// NOT a foreign key — downloads must survive the songs table being rebuilt
  /// during library sync. The relationship is purely logical.
  TextColumn get songId => text()();

  TextColumn get filePath => text()();

  /// `filesystem` for ordinary paths and `androidSaf` for persisted Android
  /// Storage Access Framework document URIs.
  TextColumn get storageKind =>
      text().withDefault(const Constant('filesystem'))();

  IntColumn get fileSize => integer()();

  TextColumn get format => text()();

  IntColumn get bitRate => integer().nullable()();

  DateTimeColumn get lastAccessedAt => dateTime()();

  TextColumn get cacheType => textEnum<CacheType>()();

  TextColumn get downloadStatus => textEnum<DownloadStatus>()();

  @override
  Set<Column<Object>> get primaryKey => {songId};
}
