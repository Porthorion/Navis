import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';

part 'star_sync_dao.g.dart';

@DriftAccessor(tables: [StarSyncQueueTable])
class StarSyncDao extends DatabaseAccessor<NavisDatabase>
    with NavisDaoTransactions, _$StarSyncDaoMixin {
  new(super.attachedDatabase);

  static const dispatchLeaseTtl = Duration(minutes: 1);

  Future<bool> acquireDispatchLease(String owner, DateTime now) =>
      transaction(() async {
        await customStatement(
          'INSERT INTO annotation_dispatch_lease (id, owner_token, expires_at) '
          'VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET owner_token = excluded.owner_token, '
          'expires_at = excluded.expires_at WHERE annotation_dispatch_lease.expires_at <= ?',
          [
            owner,
            now.add(dispatchLeaseTtl).millisecondsSinceEpoch ~/ 1000,
            now.millisecondsSinceEpoch ~/ 1000,
          ],
        );
        final row = await customSelect(
          'SELECT owner_token FROM annotation_dispatch_lease WHERE id = 1',
        ).getSingle();
        return row.read<String>('owner_token') == owner;
      });

  Future<bool> renewDispatchLease(String owner, DateTime now) async =>
      await customUpdate(
        'UPDATE annotation_dispatch_lease SET expires_at = ? WHERE id = 1 AND owner_token = ? AND expires_at > ?',
        variables: [
          Variable.withDateTime(now.add(dispatchLeaseTtl)),
          Variable.withString(owner),
          Variable.withDateTime(now),
        ],
      ) ==
      1;

  Future<void> releaseDispatchLease(String owner) => customStatement(
    'DELETE FROM annotation_dispatch_lease WHERE id = 1 AND owner_token = ?',
    [owner],
  );

  /// Ownership and acknowledgement share the SQLite writer transaction.
  Future<bool> withDispatchLease(
    String owner,
    DateTime now,
    Future<void> Function() write,
  ) => transaction(() async {
    final owned = await customUpdate(
      'UPDATE annotation_dispatch_lease SET owner_token = owner_token '
      'WHERE id = 1 AND owner_token = ? AND expires_at > ?',
      variables: [Variable.withString(owner), Variable.withDateTime(now)],
    );
    if (owned != 1) return false;
    await write();
    return true;
  });

  Future<bool> toggleSongStarred(String songId) => transaction(() async {
    final liked =
        await attachedDatabase.libraryDao.getSongStarred(songId) == null;
    await setStarred(itemId: songId, itemType: 'song', liked: liked);
    return liked;
  });

  /// Persist a local star and its delivery version in the same transaction.
  Future<void> setStarred({
    required String itemId,
    required String itemType,
    required bool liked,
  }) {
    return transaction(() async {
      final at = liked ? DateTime.now() : null;
      switch (itemType) {
        case 'song':
          await attachedDatabase.libraryDao.updateSongStarred(itemId, at);
        case 'album':
          await attachedDatabase.libraryDao.updateAlbumStarred(itemId, at);
        case 'artist':
          await attachedDatabase.libraryDao.updateArtistStarred(itemId, at);
        default:
          throw ArgumentError.value(itemType, 'itemType');
      }
      await queueStarAction(
        itemId: itemId,
        itemType: itemType,
        action: liked ? 'star' : 'unstar',
      );
    });
  }

  Future<void> setRating({
    required String itemId,
    required String itemType,
    required int rating,
  }) {
    final normalized = rating.clamp(0, 5);
    return transaction(() async {
      final value = normalized == 0 ? null : normalized;
      switch (itemType) {
        case 'song':
          await attachedDatabase.libraryDao.updateSongRating(itemId, value);
        case 'album':
          await attachedDatabase.libraryDao.updateAlbumRating(itemId, value);
        default:
          throw ArgumentError.value(itemType, 'itemType');
      }
      await _queue(
        itemId: itemId,
        itemType: itemType,
        operation: 'rating',
        action: '$normalized',
      );
    });
  }

  /// Supersedes only the same annotation field. The new auto-increment ID is
  /// its delivery version, so an older acknowledgement cannot delete it.
  Future<void> queueStarAction({
    required String itemId,
    required String itemType,
    required String action,
  }) {
    if (!const ['song', 'album', 'artist'].contains(itemType) ||
        !const ['star', 'unstar'].contains(action)) {
      throw ArgumentError('Invalid star operation');
    }
    return _queue(
      itemId: itemId,
      itemType: itemType,
      operation: 'star',
      action: action,
    );
  }

  Future<void> _queue({
    required String itemId,
    required String itemType,
    required String operation,
    required String action,
  }) {
    return transaction(() async {
      await (delete(starSyncQueueTable)..where(
            (t) =>
                t.itemId.equals(itemId) &
                t.itemType.equals(itemType) &
                t.operation.equals(operation),
          ))
          .go();
      await into(starSyncQueueTable).insert(
        StarSyncQueueTableCompanion.insert(
          itemId: itemId,
          itemType: itemType,
          action: action,
          operation: Value(operation),
          queuedAt: DateTime.now(),
        ),
      );
    });
  }

  /// Get all pending star/unstar operations in queue order.
  Future<List<StarSyncQueueTableData>> getPendingActions({String? operation}) {
    final query = select(starSyncQueueTable)
      ..orderBy([(t) => OrderingTerm.asc(t.id)]);
    if (operation != null) {
      query.where((row) => row.operation.equals(operation));
    }
    return query.get();
  }

  Future<StarSyncQueueTableData?> nextDue(DateTime now) {
    return (select(starSyncQueueTable)
          ..where(
            (t) =>
                t.notBefore.isNull() | t.notBefore.isSmallerOrEqualValue(now),
          )
          ..orderBy([(t) => OrderingTerm.asc(t.id)])
          ..limit(1))
        .getSingleOrNull();
  }

  Future<bool> isCurrent(int id) async =>
      (await (select(
        starSyncQueueTable,
      )..where((t) => t.id.equals(id))).getSingleOrNull()) !=
      null;

  Future<void> recordFailure(
    StarSyncQueueTableData entry, {
    required String errorType,
    required DateTime retryAt,
  }) async {
    await (update(
      starSyncQueueTable,
    )..where((t) => t.id.equals(entry.id))).write(
      StarSyncQueueTableCompanion(
        attemptCount: Value(entry.attemptCount + 1),
        notBefore: Value(retryAt),
        lastErrorType: Value(errorType),
      ),
    );
  }

  Stream<List<StarSyncQueueTableData>> watchPendingActions() =>
      select(starSyncQueueTable).watch();

  Future<void> releaseAuthenticationFailures() async {
    await (update(
      starSyncQueueTable,
    )..where((t) => t.lastErrorType.equals('authentication'))).write(
      const StarSyncQueueTableCompanion(
        notBefore: Value(null),
        lastErrorType: Value(null),
      ),
    );
  }

  /// Remove a single completed action from the queue.
  Future<int> removeAction(int id) {
    return (delete(starSyncQueueTable)..where((t) => t.id.equals(id))).go();
  }

  /// Clear all pending actions (e.g., after sign-out).
  Future<int> clearAll() {
    return delete(starSyncQueueTable).go();
  }

  /// Watch the queue count for UI indicators.
  Stream<int> watchPendingCount() {
    final countExpr = starSyncQueueTable.id.count();
    return (selectOnly(starSyncQueueTable)..addColumns([countExpr]))
        .map((row) => row.read(countExpr)!)
        .watchSingle();
  }
}
