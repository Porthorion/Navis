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

  /// The title, artist, and album keys used to match external track lists
  /// (Last.fm top tracks, recommendations) to local songs, in the
  /// `normalizeMetadata` form. Null only for rows written before schema 87,
  /// which are treated as stale.
  TextColumn get matchTitle => text().nullable()();

  TextColumn get matchArtist => text().nullable()();

  TextColumn get matchAlbum => text().nullable()();

  @override
  Set<Column> get primaryKey => {songId};

  @override
  bool get withoutRowId => true;
}
