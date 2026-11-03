import 'package:drift/drift.dart';

/// One row per song and genre merge key, so genre pages can count and list
/// songs with indexed lookups instead of decoding every `songs.genres`.
///
/// Rows are derived data maintained lazily, like `song_search_text` and
/// `album_artist_index`: a row is current only while [source] equals the
/// song's raw `genres` JSON followed by U+001F and the `genreKeyVersion` its
/// key was built with. Only catalog songs (neither provisional nor external)
/// are indexed. Readers repair stale or missing rows before querying, so
/// song write paths need not know about this table.
class SongGenreIndexTable extends Table {
  @override
  String get tableName => 'song_genre_index';

  TextColumn get songId => text()();

  /// The merge key, see `genreKey`.
  TextColumn get genreKey => text()();

  /// The server's spelling, for choosing the most common display name.
  TextColumn get name => text()();

  TextColumn get source => text()();

  @override
  Set<Column> get primaryKey => {songId, genreKey};

  @override
  bool get withoutRowId => true;
}
