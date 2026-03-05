import 'package:drift/drift.dart';

class ExternalLyricsCacheTable extends Table {
  @override
  String get tableName => 'external_lyrics_cache';

  TextColumn get songId => text()();

  TextColumn get source => text()();

  TextColumn get syncedLyrics => text().nullable()();

  TextColumn get plainLyrics => text().nullable()();

  DateTimeColumn get fetchedAt => dateTime()();

  IntColumn get ttlSeconds => integer().withDefault(const Constant(86400))();

  IntColumn get failureCount => integer().withDefault(const Constant(0))();

  DateTimeColumn get lastFailedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {songId};
}
