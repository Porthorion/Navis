import 'package:drift/drift.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

class PlayQueueTable extends Table {
  @override
  String get tableName => 'play_queue';

  IntColumn get id => integer()();

  IntColumn get currentIndex => integer().nullable()();

  TextColumn get shuffleMode =>
      textEnum<ShuffleMode>().withDefault(const Constant('off'))();

  TextColumn get repeatMode =>
      textEnum<RepeatMode>().withDefault(const Constant('off'))();

  IntColumn get positionMs => integer().withDefault(const Constant(0))();

  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
