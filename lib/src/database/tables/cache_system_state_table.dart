import 'package:drift/drift.dart';

/// Durable marker for one-time playback-cache contract migrations.
class CacheSystemStateTable extends Table {
  @override
  String get tableName => 'cache_system_state';

  IntColumn get id => integer()();

  IntColumn get cacheSystemVersion => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
