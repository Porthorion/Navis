import 'package:drift/drift.dart';

class NetworkUsageTable extends Table {
  @override
  String get tableName => 'network_usage_events';

  IntColumn get id => integer().autoIncrement()();

  /// Stable category key such as `audio_stream`, `cover_art`, or `library_sync`.
  TextColumn get category => text()();

  /// Stable operation name, usually the Subsonic endpoint path.
  TextColumn get operation => text().nullable()();

  /// `wifi`, `cellular`, `offline`, or `other`.
  TextColumn get networkType => text()();

  IntColumn get bytes => integer().withDefault(const Constant(0))();

  IntColumn get requestCount => integer().withDefault(const Constant(1))();

  DateTimeColumn get occurredAt => dateTime()();
}
