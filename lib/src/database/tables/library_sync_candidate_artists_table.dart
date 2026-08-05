import 'package:drift/drift.dart';

class LibrarySyncCandidateArtistsTable extends Table {
  @override
  String get tableName => 'library_sync_candidate_artists';

  IntColumn get serverId => integer()();

  IntColumn get generation => integer()();

  TextColumn get id => text()();

  TextColumn get name => text()();

  IntColumn get albumCount => integer().nullable()();

  TextColumn get coverArt => text().nullable()();

  DateTimeColumn get starred => dateTime().nullable()();

  /// Null while the candidate still needs comparison, zero when it matches
  /// the committed row, and one when promotion must insert or update it.
  IntColumn get applyState => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {serverId, generation, id};
}
