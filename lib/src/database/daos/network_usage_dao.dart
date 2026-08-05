import 'package:drift/drift.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/database/tables/network_usage_table.dart';

part 'network_usage_dao.g.dart';

class NetworkUsageCategoryTotal {
  const NetworkUsageCategoryTotal({
    required this.category,
    required this.networkType,
    required this.bytes,
    required this.requestCount,
  });

  final String category;
  final String networkType;
  final int bytes;
  final int requestCount;
}

class NetworkUsageTotal {
  const NetworkUsageTotal({
    required this.bytes,
    required this.requestCount,
  });

  final int bytes;
  final int requestCount;
}

@DriftAccessor(tables: [NetworkUsageTable])
class NetworkUsageDao extends DatabaseAccessor<NavisDatabase>
    with _$NetworkUsageDaoMixin {
  NetworkUsageDao(super.attachedDatabase);

  Future<void> recordUsage({
    required String category,
    String? operation,
    required String networkType,
    required int bytes,
    int requestCount = 1,
    DateTime? occurredAt,
  }) async {
    if (bytes <= 0 && requestCount <= 0) {
      return;
    }
    await into(networkUsageTable).insert(
      NetworkUsageTableCompanion.insert(
        category: category,
        operation: Value(operation),
        networkType: networkType,
        bytes: Value(bytes < 0 ? 0 : bytes),
        requestCount: Value(requestCount < 1 ? 1 : requestCount),
        occurredAt: occurredAt ?? DateTime.now(),
      ),
    );
  }

  Stream<List<NetworkUsageCategoryTotal>> watchCategoryTotalsSince(
    DateTime since,
  ) {
    return customSelect(
      '''
      SELECT
        category,
        network_type,
        SUM(bytes) AS total_bytes,
        SUM(request_count) AS total_requests
      FROM network_usage_events
      WHERE occurred_at >= ?
      GROUP BY category, network_type
      ORDER BY total_bytes DESC, category ASC, network_type ASC;
      ''',
      variables: <Variable<Object>>[Variable<DateTime>(since)],
      readsFrom: {networkUsageTable},
    ).watch().map((rows) {
      return rows
          .map(
            (row) => NetworkUsageCategoryTotal(
              category: row.read<String>('category'),
              networkType: row.read<String>('network_type'),
              bytes: row.read<int>('total_bytes'),
              requestCount: row.read<int>('total_requests'),
            ),
          )
          .toList(growable: false);
    });
  }

  Stream<NetworkUsageTotal> watchTotalSince(DateTime since) {
    final bytes = networkUsageTable.bytes.sum();
    final requests = networkUsageTable.requestCount.sum();
    final query = selectOnly(networkUsageTable)
      ..where(networkUsageTable.occurredAt.isBiggerOrEqualValue(since))
      ..addColumns([bytes, requests]);
    return query.watchSingle().map(
      (row) => NetworkUsageTotal(
        bytes: row.read(bytes) ?? 0,
        requestCount: row.read(requests) ?? 0,
      ),
    );
  }

  Future<NetworkUsageTotal> getCategoryTotalSince({
    required String category,
    required DateTime since,
  }) async {
    final bytes = networkUsageTable.bytes.sum();
    final requests = networkUsageTable.requestCount.sum();
    final query = selectOnly(networkUsageTable)
      ..where(
        networkUsageTable.occurredAt.isBiggerOrEqualValue(since) &
            networkUsageTable.category.equals(category),
      )
      ..addColumns([bytes, requests]);
    final row = await query.getSingle();
    return NetworkUsageTotal(
      bytes: row.read(bytes) ?? 0,
      requestCount: row.read(requests) ?? 0,
    );
  }

  Future<void> pruneOlderThan(DateTime cutoff) {
    return (delete(
      networkUsageTable,
    )..where((table) => table.occurredAt.isSmallerThanValue(cutoff))).go();
  }

  Future<void> clearAll() {
    return delete(networkUsageTable).go();
  }
}
