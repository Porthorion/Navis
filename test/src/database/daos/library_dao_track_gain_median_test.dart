import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/library_dao.dart';
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

  Future<LibraryGainStats> median() =>
      db.libraryDao.trackGainMedian(maxAbsDb: 24);

  test('an empty library has no median', () async {
    final result = await median();
    expect(result.count, 0);
    expect(result.median, isNull);
    expect(result.total, 0);
    expect(result.withData, 0);
  });

  test('coverage counts songs with a usable track or album gain', () async {
    Future<void> add(String id, {double? track, double? album}) => db
        .into(db.songsTable)
        .insert(
          SongsTableCompanion.insert(
            id: id,
            title: id,
            replayGainTrackGain: Value(track),
            replayGainAlbumGain: Value(album),
          ),
        );
    await add('track', track: -9);
    await add('album-only', album: -7);
    await add('both', track: -9, album: -7);
    await add('garbage-track-good-album', track: 918, album: -7);
    await add('garbage-only', track: 918, album: -40);
    await add('none');
    final result = await median();
    expect(result.total, 6);
    expect(result.withData, 4);
    // Only track gains feed the Automatic level.
    expect(result.count, 2);
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
    expect(result.total, 3);
    expect(result.withData, 3);
  });
}
