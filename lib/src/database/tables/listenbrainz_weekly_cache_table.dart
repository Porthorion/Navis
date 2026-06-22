import 'package:drift/drift.dart';

class ListenBrainzWeeklyCacheTable extends Table {
  @override
  String get tableName => 'listenbrainz_weekly_cache';

  TextColumn get listenBrainzUserName => text()();

  TextColumn get sourcePatch => text()();

  TextColumn get playlistIdentifier => text()();

  TextColumn get title => text()();

  TextColumn get weekMarker => text().nullable()();

  DateTimeColumn get playlistDate => dateTime().nullable()();

  TextColumn get recommendationsJson => text()();

  IntColumn get matchedCount => integer().withDefault(const Constant(0))();

  IntColumn get totalCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {listenBrainzUserName, sourcePatch};
}
