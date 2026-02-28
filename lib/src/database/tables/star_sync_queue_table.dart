import 'package:drift/drift.dart';

/// Queue for star/unstar operations that failed due to connectivity.
/// Flushed when the server becomes reachable again.
class StarSyncQueueTable extends Table {
  @override
  String get tableName => 'star_sync_queue';

  IntColumn get id => integer().autoIncrement()();

  /// The ID of the item to star/unstar (song, album, or artist server ID).
  TextColumn get itemId => text()();

  /// The type of item: 'song', 'album', or 'artist'.
  TextColumn get itemType => text()();

  /// The action to perform: 'star' or 'unstar'.
  TextColumn get action => text()();

  /// When the action was queued.
  DateTimeColumn get queuedAt => dateTime()();
}
