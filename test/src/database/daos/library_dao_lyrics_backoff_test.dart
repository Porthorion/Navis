import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_database.dart';

void main() {
  test('clears backoff only for empty non-instrumental lyrics rows', () async {
    final db = createTestDatabase();
    addTearDown(db.close);
    final failedAt = DateTime.utc(2026, 10, 18);
    final fixtures = [
      (id: 'null', synced: null, plain: null, instrumental: false),
      (id: 'empty', synced: '', plain: '', instrumental: false),
      (id: 'spaces', synced: '  ', plain: ' ', instrumental: false),
      (
        id: 'synced',
        synced: '[00:01.00]words',
        plain: null,
        instrumental: false,
      ),
      (id: 'plain', synced: null, plain: 'words', instrumental: false),
      (id: 'instrumental', synced: null, plain: null, instrumental: true),
      (
        id: 'instrumental-plain',
        synced: null,
        plain: 'words',
        instrumental: true,
      ),
    ];
    for (final fixture in fixtures) {
      await db.libraryDao.upsertExternalLyricsCache(
        songId: fixture.id,
        source: 'server',
        syncedLyrics: fixture.synced,
        plainLyrics: fixture.plain,
        instrumental: fixture.instrumental,
        failureCount: 3,
        lastFailedAt: failedAt,
      );
    }
    final before = {
      for (final fixture in fixtures)
        fixture.id: (await db.libraryDao.getExternalLyricsCache(fixture.id))!,
    };

    await db.libraryDao.clearEmptyLyricsFailureBackoff();

    for (final fixture in fixtures) {
      final original = before[fixture.id]!;
      final shouldClear = const {
        'null',
        'empty',
        'spaces',
      }.contains(fixture.id);
      expect(
        await db.libraryDao.getExternalLyricsCache(fixture.id),
        shouldClear
            ? original.copyWith(
                failureCount: 0,
                lastFailedAt: const Value(null),
              )
            : original,
        reason: fixture.id,
      );
    }
  }, skip: !sqliteAvailable);
}
