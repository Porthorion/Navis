import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('sync notifications do not open locale settings off Android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(librarySyncNotifierProvider);
    expect(container.exists(appLocaleProvider), isFalse);
    expect(container.exists(navisDatabaseProvider), isFalse);

    const state = LibrarySyncState(
      status: LibrarySyncStatus.idle,
      stage: LibrarySyncStage.idle,
    );
    await notifier.showProgress(state);
    await notifier.showComplete(state);
    await notifier.showFailed(state);
    await notifier.dismissProgress();
    await Future<void>.delayed(Duration.zero);

    expect(container.exists(appLocaleProvider), isFalse);
    expect(container.exists(appSettingsProvider), isFalse);
    expect(container.exists(navisDatabaseProvider), isFalse);
  });
  test('download provider does not resolve notification locale', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final database = createTestDatabase();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          appLocaleProvider.overrideWith(
            (ref) => throw StateError('locale read'),
          ),
          customDownloadFolderEnabledProvider.overrideWithValue(true),
          customDownloadFolderPathProvider.overrideWithValue(null),
          wifiOnlyDownloadsProvider.overrideWithValue(false),
          networkTypeProvider.overrideWithValue(NetworkType.wifi),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final service = container.read(downloadServiceProvider);
    await service.start();
    await service.stop();
    expect(container.exists(appLocaleProvider), isFalse);
  }, skip: !sqliteAvailable);
}
