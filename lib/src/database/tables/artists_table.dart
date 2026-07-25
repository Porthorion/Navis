import 'package:drift/drift.dart';

class ArtistsTable extends Table {
  @override
  String get tableName => 'artists';

  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get albumCount => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  /// True for lightweight parent rows created from online search/playback
  /// results before the authoritative library sync has observed the artist.
  BoolColumn get isProvisional =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
