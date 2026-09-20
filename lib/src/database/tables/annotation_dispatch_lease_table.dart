import 'package:drift/drift.dart';

/// One outbound annotation writer per database, including other app processes.
class AnnotationDispatchLeaseTable extends Table {
  @override
  String get tableName => 'annotation_dispatch_lease';
  IntColumn get id => integer()();
  TextColumn get ownerToken => text()();
  DateTimeColumn get expiresAt => dateTime()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}
