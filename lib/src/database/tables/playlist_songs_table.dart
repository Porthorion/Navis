import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/playlists_table.dart';
import 'package:navis/src/database/tables/songs_table.dart';

class PlaylistSongsTable extends Table {
  @override
  String get tableName => 'playlist_songs';

  TextColumn get playlistId =>
      text().references(PlaylistsTable, #id, onDelete: KeyAction.cascade)();

  TextColumn get songId =>
      text().references(SongsTable, #id, onDelete: KeyAction.cascade)();

  IntColumn get sortOrder => integer()();

  @override
  Set<Column<Object>> get primaryKey => {playlistId, songId};
}
