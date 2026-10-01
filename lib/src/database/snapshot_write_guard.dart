import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';

/// Read inside the write transaction, after the network response arrives.
/// Successful local edits remain protected even after their outbox is drained.
class SnapshotWriteGuard {
  new(this._stars, this._ratings, this._pending);

  final Set<String> _stars;
  final Set<String> _ratings;
  final Map<String, DateTime?> _pending;

  static Future<SnapshotWriteGuard> read(
    NavisDatabase db,
    DateTime? since,
  ) async {
    final mutations = since == null
        ? <LibrarySyncLocalMutationsTableData>[]
        : await (db.select(
            db.librarySyncLocalMutationsTable,
          )..where((row) => row.createdAt.isBiggerOrEqualValue(since))).get();
    final pending = await db.select(db.starSyncQueueTable).get();
    return SnapshotWriteGuard(
      {
        for (final row in mutations)
          if (row.operation == 'star') '${row.entityType}:${row.entityId}',
      },
      {
        for (final row in mutations)
          if (row.operation == 'rating') '${row.entityType}:${row.entityId}',
        for (final row in pending)
          if (row.operation == 'rating') '${row.itemType}:${row.itemId}',
      },
      {
        for (final row in pending)
          if (row.operation == 'star')
            '${row.itemType}:${row.itemId}': row.action == 'star'
                ? row.queuedAt
                : null,
      },
    );
  }

  Value<DateTime?> _star(String type, String id, Value<DateTime?> incoming) {
    final key = '$type:$id';
    if (_stars.contains(key)) return const Value.absent();
    return _pending.containsKey(key) ? Value(_pending[key]) : incoming;
  }

  ArtistsTableCompanion artist(ArtistsTableCompanion row) =>
      row.copyWith(starred: _star('artist', row.id.value, row.starred));

  AlbumsTableCompanion album(AlbumsTableCompanion row) => row.copyWith(
    starred: _star('album', row.id.value, row.starred),
    userRating: _ratings.contains('album:${row.id.value}')
        ? const Value.absent()
        : row.userRating,
  );

  SongsTableCompanion song(SongsTableCompanion row) => row.copyWith(
    starred: _star('song', row.id.value, row.starred),
    userRating: _ratings.contains('song:${row.id.value}')
        ? const Value.absent()
        : row.userRating,
  );
}
