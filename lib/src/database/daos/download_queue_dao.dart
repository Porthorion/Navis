import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/download_queue_table.dart';
import 'package:navis/src/database/tables/schema_enums.dart';

part 'download_queue_dao.g.dart';

@DriftAccessor(tables: [DownloadQueueTable])
class DownloadQueueDao extends DatabaseAccessor<NavisDatabase>
    with _$DownloadQueueDaoMixin {
  new(super.attachedDatabase);

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
    return (update(downloadQueueTable)..where((table) => table.id.equals(id)))
        .write(DownloadQueueTableCompanion(progress: Value(progress)));
  }

  Future<void> updateStatus(int id, DownloadStatus status) {
    return (update(downloadQueueTable)..where((table) => table.id.equals(id)))
        .write(DownloadQueueTableCompanion(status: Value(status)));
  }

  Future<void> remove(int id) {
    return (delete(
      downloadQueueTable,
    )..where((table) => table.id.equals(id))).go();
  }

  Future<void> clearQueue() {
    return delete(downloadQueueTable).go();
  }

  /// Look up a queue item by [songId]. Returns `null` if not found.
  Future<DownloadQueueTableData?> findBySongId(String songId) {
    final query = select(downloadQueueTable)
      ..where((t) => t.songId.equals(songId))
      ..limit(1);
    return query.getSingleOrNull();
  }

  /// Return only items with status [DownloadStatus.queued], ordered by priority
  /// then addedAt.  Used by the download service to pick the next item.
  Future<List<DownloadQueueTableData>> getQueuedItems() {
    final query = select(downloadQueueTable)
      ..where((t) => t.status.equalsValue(DownloadStatus.queued))
      ..orderBy([
        (t) => OrderingTerm.desc(t.priority),
        (t) => OrderingTerm.asc(t.addedAt),
      ]);
    return query.get();
  }

  /// Reset any items stuck in `downloading` back to `queued`.
  ///
  /// Call on startup to recover from a previous app kill.
  /// Returns how many downloads were interrupted.
  Future<int> requeueStuckDownloads() {
    return (update(
      downloadQueueTable,
    )..where((t) => t.status.equalsValue(DownloadStatus.downloading))).write(
      const DownloadQueueTableCompanion(
        status: Value(DownloadStatus.queued),
        progress: Value(0),
      ),
    );
  }

  /// Reset all failed items to `queued` so they can be retried.
  Future<void> retryAllFailed() {
    return (update(
      downloadQueueTable,
    )..where((t) => t.status.equalsValue(DownloadStatus.failed))).write(
      const DownloadQueueTableCompanion(
        status: Value(DownloadStatus.queued),
        progress: Value(0),
        retryCount: Value(0),
      ),
    );
  }

  /// Return the set of songIds that are currently queued or downloading.
  Future<Set<String>> getActiveSongIds() async {
    final query = selectOnly(downloadQueueTable)
      ..where(
        downloadQueueTable.status.isIn([
          DownloadStatus.queued.name,
          DownloadStatus.downloading.name,
        ]),
      )
      ..addColumns([downloadQueueTable.songId]);
    final rows = await query.get();
    return rows
        .map((r) => r.read(downloadQueueTable.songId))
        .whereType<String>()
        .toSet();
  }

  /// Batch-insert multiple queue items in a single transaction.
  Future<void> enqueueBatch(
    List<DownloadQueueTableCompanion> companions,
  ) async {
    if (companions.isEmpty) return;
    await batch((b) {
      b.insertAll(downloadQueueTable, companions);
    });
  }

  /// Increment the retry count for a queue item.
  Future<void> incrementRetryCount(int id) {
    return customStatement(
      'UPDATE download_queue SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  /// Update status and increment retry count atomically.
  Future<void> markForRetry(int id) async {
    // A custom update that names its table, so queue watchers (the Downloads
    // screen) see the row return to the queue.
    await customUpdate(
      'UPDATE download_queue SET status = ?, progress = 0, '
      'retry_count = retry_count + 1 WHERE id = ?',
      variables: <Variable<Object>>[
        Variable<String>(DownloadStatus.queued.name),
        Variable<int>(id),
      ],
      updates: <TableInfo<Table, Object?>>{downloadQueueTable},
      updateKind: UpdateKind.update,
    );
  }
}
