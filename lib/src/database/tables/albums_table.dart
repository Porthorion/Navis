import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/artists_table.dart';

class AlbumsTable extends Table {
  @override
  String get tableName => 'albums';

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get artistId => text().nullable().references(
    ArtistsTable,
    #id,
    onDelete: KeyAction.setNull,
  )();

  TextColumn get artistName => text().nullable()();

  IntColumn get songCount => integer().nullable()();

  IntColumn get duration => integer().nullable()();

  IntColumn get year => integer().nullable()();

  TextColumn get genre => text().nullable()();

  TextColumn get coverArt => text().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  IntColumn get playCount => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
