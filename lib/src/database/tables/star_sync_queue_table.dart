import 'package:drift/drift.dart';

/// Latest unacknowledged annotation per entity and field.
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

  /// 'star' or 'rating'; ratings use action '0' through '5'.
  TextColumn get operation => text().withDefault(const Constant('star'))();

  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get notBefore => dateTime().nullable()();
  TextColumn get lastErrorType => text().nullable()();

  /// When the action was queued.
  DateTimeColumn get queuedAt => dateTime()();
}
