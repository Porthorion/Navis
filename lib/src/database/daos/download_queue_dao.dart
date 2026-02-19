import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

part 'download_queue_dao.g.dart';

@DriftAccessor(tables: [DownloadQueueTable])
class DownloadQueueDao extends DatabaseAccessor<NavisDatabase>
    with _$DownloadQueueDaoMixin {
  DownloadQueueDao(super.db);

  Stream<List<DownloadQueueTableData>> watchQueue() {
    final query = select(downloadQueueTable)
      ..orderBy([
        (table) => OrderingTerm.desc(table.priority),
        (table) => OrderingTerm.asc(table.addedAt),
      ]);
    return query.watch();
  }

  Future<int> enqueue(DownloadQueueTableCompanion companion) {
    return into(downloadQueueTable).insert(companion);
  }

  Future<void> updateProgress(int id, double progress) {
    return (update(
      downloadQueueTable,
    )..where((table) => table.id.equals(id))).write(
      DownloadQueueTableCompanion(progress: Value(progress)),
    );
  }

  Future<void> updateStatus(int id, DownloadStatus status) {
    return (update(
      downloadQueueTable,
    )..where((table) => table.id.equals(id))).write(
      DownloadQueueTableCompanion(status: Value(status)),
    );
  }

  Future<void> remove(int id) {
    return (delete(
      downloadQueueTable,
    )..where((table) => table.id.equals(id))).go();
  }
}
