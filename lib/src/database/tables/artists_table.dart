import 'package:drift/drift.dart';

class ArtistsTable extends Table {
  @override
  String get tableName => 'artists';

  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get albumCount => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  /// Incremented on targeted artwork recovery. Zero keeps the legacy
  /// cache-key layout so existing offline artwork stays valid.
  /// Nullable so rows never refreshed keep legacy data-class behavior;
  /// treat null as revision zero when composing cache keys.
  IntColumn get coverArtRevision => integer().nullable()();

  /// MusicBrainz artist identifier, when the server supplies one. Used to
  /// map artists across server ID changes without metadata guessing.
  TextColumn get artistMbid => text().nullable()();

  /// Typed catalog availability. Null reads as present for legacy rows.
  TextColumn get catalogAvailability => text().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  /// True for lightweight parent rows created from online search/playback
  /// results before the authoritative library sync has observed the artist.
  BoolColumn get isProvisional =>
      boolean().withDefault(const Constant(false))();

  /// True when the item belongs to an external catalog and has not been
  /// imported into the server library.
  BoolColumn get isExternal => boolean().withDefault(const Constant(false))();

  /// Authoritative catalog snapshot generation that last observed this row.
  /// Generation zero denotes rows that predate the resumable sync planner.
  IntColumn get catalogGeneration => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
