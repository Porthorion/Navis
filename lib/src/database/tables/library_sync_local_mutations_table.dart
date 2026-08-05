import 'package:drift/drift.dart';

class LibrarySyncLocalMutationsTable extends Table {
  @override
  String get tableName => 'library_sync_local_mutations';

  IntColumn get id => integer().autoIncrement()();

  TextColumn get entityType => text()();

  TextColumn get entityId => text()();

  TextColumn get operation => text()();

  DateTimeColumn get createdAt => dateTime()();
}
