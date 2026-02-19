import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/albums_table.dart';
import 'package:navis/src/database/tables/playlists_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class DownloadQueueTable extends Table {
  @override
  String get tableName => 'download_queue';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get songId => text().nullable().references(
    SongsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get albumId => text().nullable().references(
    AlbumsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get playlistId => text().nullable().references(
    PlaylistsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get quality => text().nullable()();

  TextColumn get format => text().nullable()();

  TextColumn get status => textEnum<DownloadStatus>()();

  RealColumn get progress => real().withDefault(const Constant(0))();

  DateTimeColumn get addedAt => dateTime()();

  IntColumn get priority => integer().withDefault(const Constant(0))();
}
