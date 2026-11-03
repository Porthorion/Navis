import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';

import '../../../../helpers/test_database.dart';

void main() {
  test('genresPendingSyncProvider follows the sync model stamp, written after '
      'the sync reports completion', () async {
    final database = createTestDatabase();
    final container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final seen = <bool>[];
    container.listen(
      genresPendingSyncProvider,
      (_, next) => next.whenData(seen.add),
      fireImmediately: true,
    );
    await database.appSettingsDao.getSettings();
    await container.read(genresPendingSyncProvider.future);

    // Not stamped for this sync model yet: genres are still pending.
    expect(seen.last, isTrue);

    await database.appSettingsDao.setLastFullSyncAppBuild(
      currentLibrarySyncModelVersion,
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.last, isFalse);

    // An older stamp (a library from before genres) is pending again.
    await database.appSettingsDao.setLastFullSyncAppBuild('58');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen.last, isTrue);
  }, skip: !sqliteAvailable);
}
