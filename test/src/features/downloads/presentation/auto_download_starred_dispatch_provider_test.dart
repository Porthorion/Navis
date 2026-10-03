import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/domain/server_reachability.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

class _MockDownloadService extends Mock implements DownloadService;

class _OnlineReachability extends ServerReachabilityController {
  @override
  ServerReachabilityState build() =>
      const ServerReachabilityState(status: ServerReachabilityStatus.online);
}

void main() {
  late NavisDatabase database;
  late _MockDownloadService service;

  setUp(() async {
    database = createTestDatabase();
    service = _MockDownloadService();
    when(
      () => service.enqueueSong(
        any(),
        quality: any(named: 'quality'),
        format: any(named: 'format'),
      ),
    ).thenAnswer((_) async {});
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'liked',
        title: 'Liked',
        starred: Value(DateTime(2026)),
      ),
    ]);
  });

  tearDown(() => database.close());

  Future<void> dispatch() async {
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          downloadServiceProvider.overrideWithValue(service),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://music.example.test',
                username: 'listener',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
          serverReachabilityControllerProvider.overrideWith(
            _OnlineReachability.new,
          ),
          networkTypeProvider.overrideWithValue(NetworkType.wifi),
          wifiOnlyDownloadsProvider.overrideWithValue(true),
          autoDownloadStarredOnWifiProvider.overrideWithValue(true),
        ],
      ),
    );
    addTearDown(container.dispose);
    container.listen(autoDownloadStarredDispatchControllerProvider, (_, _) {});
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('liked songs download in the saved quality on Wi-Fi', () async {
    await database.appSettingsDao.updateDownloadQuality(
      mode: DownloadQualityMode.transcode,
      bitRate: 256,
      format: 'aac',
    );
    await dispatch();
    verify(() => service.enqueueSong('liked', quality: '256', format: 'aac'))
        .called(1);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'with no saved quality, liked songs download in original quality',
    () async {
      await dispatch();
      verify(() => service.enqueueSong('liked')).called(1);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );
}
