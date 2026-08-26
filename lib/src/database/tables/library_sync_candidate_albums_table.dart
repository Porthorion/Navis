import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/artist_ref_converter.dart';

class LibrarySyncCandidateAlbumsTable extends Table {
  @override
  String get tableName => 'library_sync_candidate_albums';

  IntColumn get serverId => integer()();

  IntColumn get generation => integer()();

  TextColumn get id => text()();

  TextColumn get name => text()();

  TextColumn get artistId => text().nullable()();

  TextColumn get artistName => text().nullable()();

  TextColumn get artists => text()
      .withDefault(const Constant('[]'))
      .map(const ArtistRefListConverter())();

  IntColumn get songCount => integer().nullable()();

  IntColumn get duration => integer().nullable()();

  IntColumn get year => integer().nullable()();

  TextColumn get genre => text().nullable()();

  TextColumn get coverArt => text().nullable()();

  BoolColumn get songsHydrated =>
      boolean().withDefault(const Constant(false))();

  BoolColumn get carriedForward =>
      boolean().withDefault(const Constant(false))();

  DateTimeColumn get starred => dateTime().nullable()();

  IntColumn get userRating => integer().nullable()();

  IntColumn get playCount => integer().nullable()();

  DateTimeColumn get syncedAt => dateTime().nullable()();

  DateTimeColumn get serverCreatedAt => dateTime().nullable()();

  /// Position in the complete server `newest` snapshot. This is promoted
  /// atomically with the candidate catalog so repairs cannot lose ordering.
  IntColumn get recentlyAddedRank => integer().nullable()();

  /// Null while the candidate still needs comparison, zero when it matches
  /// the committed row, and one when promotion must insert or update it.
  IntColumn get applyState => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {serverId, generation, id};
}
