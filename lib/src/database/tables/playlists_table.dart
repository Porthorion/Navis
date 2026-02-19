import 'package:drift/drift.dart';

class PlaylistsTable extends Table {
  @override
  String get tableName => 'playlists';

  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get songCount => integer().nullable()();

  IntColumn get duration => integer().nullable()();

  TextColumn get owner => text().nullable()();

  BoolColumn get isPublic => boolean().nullable()();

  TextColumn get coverArt => text().nullable()();

  TextColumn get comment => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
