import 'package:drift/drift.dart';

/// Artist keys of each album, so an artist page can find its albums with one
/// lookup instead of classifying every album in the library.
///
/// Rows are derived data maintained lazily, like `song_search_text`: a row is
/// current only while [source] equals the album's raw artist id, artist name,
/// and artist credits joined by U+001F, followed by the `metadataKeyVersion`
/// its name keys were built with. Readers repair stale or missing rows
/// before querying, so album write paths need not know about this table.
class AlbumArtistIndexTable extends Table {
  @override
  String get tableName => 'album_artist_index';

  TextColumn get albumId => text()();

  TextColumn get source => text()();

  /// Keys joined and wrapped by U+001F: `i:<artist id>` for the album artist
  /// and each credited artist, and `n:<normalized name>` for a name-only
  /// album artist and each credited name.
  TextColumn get artistKeys => text()();

  @override
  Set<Column> get primaryKey => {albumId};

  @override
  bool get withoutRowId => true;
}
