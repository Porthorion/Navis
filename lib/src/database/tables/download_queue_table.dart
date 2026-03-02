import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

class DownloadQueueTable extends Table {
  @override
  String get tableName => 'download_queue';

  IntColumn get id => integer().autoIncrement()();

  /// Song ID from Subsonic. NOT a foreign key — queue items must survive
  /// library sync which deletes and re-inserts songs.
  TextColumn get songId => text().nullable()();

  /// Album ID this download belongs to (for grouped display).
  TextColumn get albumId => text().nullable()();

  /// Playlist ID this download belongs to (for grouped display).
  TextColumn get playlistId => text().nullable()();

  TextColumn get quality => text().nullable()();

  TextColumn get format => text().nullable()();

  TextColumn get status => textEnum<DownloadStatus>()();

  RealColumn get progress => real().withDefault(const Constant(0))();

  DateTimeColumn get addedAt => dateTime()();

  IntColumn get priority => integer().withDefault(const Constant(0))();

  /// Number of retry attempts for failed downloads.
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
}
