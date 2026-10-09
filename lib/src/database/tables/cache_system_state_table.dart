import 'package:drift/drift.dart';

/// Durable app major/minor epoch for library-cache renewal.
class CacheSystemStateTable extends Table {
  @override
  String get tableName => 'cache_system_state';

  IntColumn get id => integer()();

  IntColumn get cacheSystemVersion => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
