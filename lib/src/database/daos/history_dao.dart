import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/play_history_table.dart';
import 'package:navis/src/database/tables/recent_searches_table.dart';

part 'history_dao.g.dart';

@DriftAccessor(tables: [PlayHistoryTable, RecentSearchesTable])
class HistoryDao extends DatabaseAccessor<NavisDatabase>
    with _$HistoryDaoMixin {
  HistoryDao(super.db);

  Stream<List<PlayHistoryTableData>> watchPlayHistory({int limit = 100}) {
    final query = select(playHistoryTable)
      ..orderBy([(table) => OrderingTerm.desc(table.playedAt)])
      ..limit(limit);
    return query.watch();
  }

  Future<void> addPlayHistory(String songId) {
    return into(playHistoryTable).insert(
      PlayHistoryTableCompanion.insert(
        songId: songId,
        playedAt: DateTime.now(),
      ),
    );
  }

  Stream<List<RecentSearchesTableData>> watchRecentSearches({int limit = 20}) {
    final query = select(recentSearchesTable)
      ..orderBy([(table) => OrderingTerm.desc(table.searchedAt)])
      ..limit(limit);
    return query.watch();
  }

  Future<void> saveSearchQuery(String queryText) {
    return into(recentSearchesTable).insertOnConflictUpdate(
      RecentSearchesTableCompanion(
        query: Value(queryText),
        searchedAt: Value(DateTime.now()),
      ),
    );
  }
}
