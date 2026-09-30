import 'package:drift/drift.dart';

/// Normalized local-search text for a song.
///
/// Rows are derived data and are maintained lazily: a row is current only
/// while [source] equals the song's raw title, artist, and album joined by
/// U+001F. Any songs write path can therefore change metadata without knowing
/// about this table; searches treat mismatched or missing rows as stale,
/// normalize them in Dart, and store the result.
class SongSearchTextTable extends Table {
  @override
  String get tableName => 'song_search_text';

  TextColumn get songId => text()();

  TextColumn get source => text()();

  TextColumn get searchText => text()();

  @override
  Set<Column> get primaryKey => {songId};

  @override
  bool get withoutRowId => true;
}
