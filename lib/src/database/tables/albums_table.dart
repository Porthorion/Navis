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

  BoolColumn get songsHydrated =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get starred => dateTime().nullable()();

  IntColumn get playCount => integer().nullable()();

  /// When this album was first persisted to the local database (synced from
  /// server).  Used for the "Recently Added" sort order.
  DateTimeColumn get syncedAt => dateTime().nullable()();

  /// When the album was added to the Subsonic server library.
  /// Populated from the `created` field in `getAlbumList2` responses.
  /// More accurate than [syncedAt] for "Recently Added" ordering.
  DateTimeColumn get serverCreatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
