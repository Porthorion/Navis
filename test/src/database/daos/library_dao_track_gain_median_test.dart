import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';

import '../../../helpers/test_database.dart';

void main() {
  late NavisDatabase db;

  setUp(() => db = createTestDatabase());
  tearDown(() => db.close());

  Future<void> seed(List<double?> gains) async {
    for (var i = 0; i < gains.length; i++) {
      await db
          .into(db.songsTable)
          .insert(
            SongsTableCompanion.insert(
              id: 's$i',
              title: 'Song $i',
              replayGainTrackGain: Value(gains[i]),
            ),
          );
    }
  }

  Future<({int count, double? median})> median() =>
      db.libraryDao.trackGainMedian(maxAbsDb: 24);

  test('an empty library has no median', () async {
    final result = await median();
    expect(result.count, 0);
    expect(result.median, isNull);
  });

  test('odd count: the middle gain', () async {
    await seed([-12, -6, -9, null, null]);
    final result = await median();
    expect(result.count, 3);
    expect(result.median, -9);
  });

  test('even count: the mean of the two middle gains', () async {
    await seed([-12, -6, -10, -8]);
    final result = await median();
    expect(result.count, 4);
    expect(result.median, -9);
  });

  test('garbage gains are neither counted nor part of the median', () async {
    await seed([-9, -9, -9, 918, 32, -40, 24.5]);
    final result = await median();
    expect(result.count, 3);
    expect(result.median, -9);
  });

  test('provisional, external and server-deleted songs are left out', () async {
    await seed([-9, -9, -9]);
    Future<void> add(String id, SongsTableCompanion Function(String) make) =>
        db.into(db.songsTable).insert(make(id));
    SongsTableCompanion song(
      String id, {
      bool provisional = false,
      bool external = false,
      DateTime? deleted,
    }) => SongsTableCompanion.insert(
      id: id,
      title: id,
      replayGainTrackGain: const Value(-20),
      isProvisional: Value(provisional),
      isExternal: Value(external),
      serverDeletedAt: Value(deleted),
    );
    await add('p', (id) => song(id, provisional: true));
    await add('e', (id) => song(id, external: true));
    await add('d', (id) => song(id, deleted: DateTime.utc(2026)));
    final result = await median();
    expect(result.count, 3);
    expect(result.median, -9);
  });
}
