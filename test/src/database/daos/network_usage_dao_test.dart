import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

void main() {
  group('NetworkUsageDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('aggregates, prunes, and clears usage rows', () async {
      final dao = database.networkUsageDao;
      final now = DateTime(2026, 6, 5, 12);
      final old = now.subtract(const Duration(days: 40));

      await dao.recordUsage(
        category: NetworkUsageCategory.audioStream.key,
        networkType: 'cellular',
        bytes: 1024,
        occurredAt: now,
      );
      await dao.recordUsage(
        category: NetworkUsageCategory.audioStream.key,
        networkType: 'cellular',
        bytes: 2048,
        occurredAt: now.add(const Duration(minutes: 1)),
      );
      await dao.recordUsage(
        category: NetworkUsageCategory.coverArt.key,
        networkType: 'wifi',
        bytes: 512,
        requestCount: 2,
        occurredAt: now,
      );
      await dao.recordUsage(
        category: NetworkUsageCategory.download.key,
        networkType: 'wifi',
        bytes: 4096,
        occurredAt: old,
      );

      final total = await dao
          .watchTotalSince(now.subtract(const Duration(days: 1)))
          .first;
      expect(total.bytes, 3584);
      expect(total.requestCount, 4);

      final categoryTotals = await dao
          .watchCategoryTotalsSince(now.subtract(const Duration(days: 1)))
          .first;
      expect(categoryTotals, hasLength(2));
      final audio = categoryTotals.firstWhere(
        (row) => row.category == NetworkUsageCategory.audioStream.key,
      );
      expect(audio.networkType, 'cellular');
      expect(audio.bytes, 3072);
      expect(audio.requestCount, 2);

      final coverArt = categoryTotals.firstWhere(
        (row) => row.category == NetworkUsageCategory.coverArt.key,
      );
      expect(coverArt.networkType, 'wifi');
      expect(coverArt.bytes, 512);
      expect(coverArt.requestCount, 2);

      await dao.pruneOlderThan(now.subtract(const Duration(days: 30)));
      final afterPrune = await dao
          .watchTotalSince(now.subtract(const Duration(days: 365)))
          .first;
      expect(afterPrune.bytes, 3584);

      await dao.clearAll();
      final afterClear = await dao
          .watchTotalSince(now.subtract(const Duration(days: 365)))
          .first;
      expect(afterClear.bytes, 0);
      expect(afterClear.requestCount, 0);
    });
  });
}
