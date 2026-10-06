import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/listenbrainz_feedback_queue_table.dart';

part 'listenbrainz_feedback_dao.g.dart';

@DriftAccessor(tables: [ListenBrainzFeedbackQueueTable])
class ListenBrainzFeedbackDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$ListenBrainzFeedbackDaoMixin {
  new(super.attachedDatabase);

  Future<void> queueFeedback({
    required String songId,
    required int score,
    required String title,
    required String artist,
    String? album,
    String? recordingMbid,
  }) {
    final now = DateTime.now();
    return transaction(() async {
      await (delete(
        listenBrainzFeedbackQueueTable,
      )..where((t) => t.songId.equals(songId))).go();
      await into(listenBrainzFeedbackQueueTable).insert(
        ListenBrainzFeedbackQueueTableCompanion.insert(
          songId: songId,
          score: score,
          title: title,
          artist: artist,
          album: Value(album),
          recordingMbid: Value(recordingMbid),
          queuedAt: now,
          nextAttemptAt: now,
          attempts: const Value(0),
          lastError: const Value(null),
        ),
      );
    });
  }

  Future<List<ListenBrainzFeedbackQueueTableData>> getDueFeedback({
    required DateTime now,
    int limit = 25,
  }) {
    return (select(listenBrainzFeedbackQueueTable)
          ..where((t) => t.nextAttemptAt.isSmallerOrEqualValue(now))
          ..orderBy([(t) => OrderingTerm.asc(t.nextAttemptAt)])
          ..limit(limit))
        .get();
  }

  Future<int> removeFeedback(int id) {
    return (delete(
      listenBrainzFeedbackQueueTable,
    )..where((t) => t.id.equals(id))).go();
  }

  Future<void> markAttemptFailed(
    ListenBrainzFeedbackQueueTableData entry,
    String error,
  ) {
    final attempts = entry.attempts + 1;
    final delayMinutes = attempts >= 6 ? 60 : 1 << (attempts - 1);
    return (update(
      listenBrainzFeedbackQueueTable,
    )..where((t) => t.id.equals(entry.id))).write(
      ListenBrainzFeedbackQueueTableCompanion(
        attempts: Value(attempts),
        nextAttemptAt: Value(
          DateTime.now().add(Duration(minutes: delayMinutes)),
        ),
        lastError: Value(error),
      ),
    );
  }

  Future<void> updateRecordingMbid(int id, String recordingMbid) {
    return (update(
      listenBrainzFeedbackQueueTable,
    )..where((t) => t.id.equals(id))).write(
      ListenBrainzFeedbackQueueTableCompanion(
        recordingMbid: Value(recordingMbid),
      ),
    );
  }

  Future<int> clearAll() {
    return delete(listenBrainzFeedbackQueueTable).go();
  }
}
