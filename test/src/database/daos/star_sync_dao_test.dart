import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import '../../../helpers/test_database.dart';

void main() {
  group('StarSyncDao', () {
    late NavisDatabase database;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'queueStarAction keeps only the latest pending action per item',
      () async {
        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'star',
        );
        await database.starSyncDao.queueStarAction(
          itemId: 'song-1',
          itemType: 'song',
          action: 'unstar',
        );

        final pending = await database.starSyncDao.getPendingActions();

        expect(pending, hasLength(1));
        expect(pending.single.itemId, 'song-1');
        expect(pending.single.itemType, 'song');
        expect(pending.single.action, 'unstar');
      },
      skip: !sqliteAvailable,
    );
  });
}
