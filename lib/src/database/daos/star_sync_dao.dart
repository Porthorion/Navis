import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/star_sync_queue_table.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/song_id_utils.dart';

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

  /// Toggles the like of [songId] and returns its new state, or null when the
  /// song is a remote catalog copy (`ext-`, or flagged external): the server cannot address it, so
  /// nothing is starred locally or queued. Callers show the "not available
  /// for remote tracks" notice where there is UI.
  Future<bool?> toggleSongStarred(String songId) => transaction(() async {
    // A row the catalogue flagged external (`pl-deezer-*`, ...) is refused
    // too, whatever its id looks like.
    final flagged = await customSelect(
      'SELECT 1 FROM songs WHERE id = ? AND is_external = 1',
      variables: [Variable.withString(songId)],
      readsFrom: {attachedDatabase.songsTable},
    ).get();
    if (!isServerAddressableSongId(songId) || flagged.isNotEmpty) {
      AppLogger.info('StarSyncDao: like refused for remote song $songId');
      return null;
    }
    final liked =
        await attachedDatabase.libraryDao.getSongStarred(songId) == null;
    await setStarred(itemId: songId, itemType: 'song', liked: liked);
    return liked;
  });

  /// Clears the local like of remote catalog copies (`ext-`, `remote-`, or
  /// flagged external) and
  /// their pending deliveries, returning how many songs lost it. Local only:
  /// the server resolves such an id to the library song, so an unstar sent
  /// for it would unstar that song. With [keepUnsent], a like whose star has
  /// not been sent yet (a pending star row) is left alone.
  Future<int> dropRemoteSongLikes({bool keepUnsent = false}) => transaction(
    () async {
      const flagged = '(SELECT id FROM songs WHERE is_external = 1)';
      const remoteId =
          "(id LIKE 'ext-%' OR id LIKE 'remote-%' OR id IN $flagged)";
      const remoteItem =
          "(item_id LIKE 'ext-%' OR item_id LIKE 'remote-%' "
          'OR item_id IN $flagged)';
      const unsent =
          "EXISTS (SELECT 1 FROM star_sync_queue q WHERE q.item_type = 'song' "
          "AND q.operation = 'star' AND q.action = 'star' "
          'AND q.item_id = songs.id)';
      final dropped = await customUpdate(
        'UPDATE songs SET starred = NULL WHERE starred IS NOT NULL '
        'AND $remoteId${keepUnsent ? ' AND NOT $unsent' : ''}',
        updates: {attachedDatabase.songsTable},
      );
      await customUpdate(
        "DELETE FROM star_sync_queue WHERE item_type = 'song' AND $remoteItem"
        "${keepUnsent ? " AND action <> 'star'" : ''}",
        updates: {starSyncQueueTable},
      );
      return dropped;
    },
  );

  /// Persist a local star and its delivery version in the same transaction.
  Future<void> setStarred({
    required String itemId,
    required String itemType,
    required bool liked,
  }) {
    return transaction(() async {
      final at = liked ? DateTime.now() : null;
      await attachedDatabase.libraryDao.setEntityStarred(itemType, itemId, at);
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
      await attachedDatabase.libraryDao.setEntityRating(
        itemType,
        itemId,
        value,
      );
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

  /// False for a song annotation addressed to a remote catalog copy.
  static Expression<bool> _isDeliverable(StarSyncQueueTable t) =>
      t.itemType.equals('song').not() |
      (t.itemId.like('ext-%').not() & t.itemId.like('remote-%').not());

  Future<StarSyncQueueTableData?> nextDue(DateTime now) {
    return (select(starSyncQueueTable)
          ..where(
            (t) =>
                (t.notBefore.isNull() |
                    t.notBefore.isSmallerOrEqualValue(now)) &
                // Remote copies are never delivered: the starred sync owns
                // what is left of them (a server would resolve the id to
                // the library song).
                _isDeliverable(t),
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

  /// Remove a single delivered action from the queue. The journal row keeps a
  /// sync run that read the server before delivery from undoing the local
  /// value, once the queue row no longer protects it (#542).
  Future<int> removeAction(int id) => transaction(() async {
    final row = await (select(
      starSyncQueueTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) return 0;
    await attachedDatabase.libraryDao.recordLocalMutation(
      entityType: row.itemType,
      entityId: row.itemId,
      operation: row.operation,
    );
    return (delete(starSyncQueueTable)..where((t) => t.id.equals(id))).go();
  });

  /// Clear all pending actions (e.g., after sign-out).
  Future<int> clearAll() {
    return delete(starSyncQueueTable).go();
  }
}
