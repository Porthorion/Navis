import 'package:drift/drift.dart';

class AlbumInfoCacheTable extends Table {
  @override
  String get tableName => 'album_info_cache';

  TextColumn get albumId => text()();

  TextColumn get notes => text().nullable()();

  TextColumn get musicBrainzId => text().nullable()();

  TextColumn get lastFmUrl => text().nullable()();

  TextColumn get smallImageUrl => text().nullable()();

  TextColumn get mediumImageUrl => text().nullable()();

  TextColumn get largeImageUrl => text().nullable()();

  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {albumId};
}
