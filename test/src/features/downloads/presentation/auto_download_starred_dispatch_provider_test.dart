import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/auth/presentation/server_reachability_provider.dart';
import 'package:navis/src/features/downloads/data/download_service.dart';
import 'package:navis/src/features/downloads/domain/download_preferences.dart';
import 'package:navis/src/features/downloads/presentation/auto_download_starred_dispatch_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';
import '../../../../helpers/reachability_fakes.dart';

class _MockDownloadService extends Mock implements DownloadService;

class _TestNetwork extends Notifier<NetworkType> {
  @override
  NetworkType build() => NetworkType.wifi;

  // A Notifier's state is protected; tests flip it through this method.
  // ignore: use_setters_to_change_properties
  void set(NetworkType type) => state = type;
}

final _testNetworkProvider = NotifierProvider<_TestNetwork, NetworkType>(
  _TestNetwork.new,
);

void main() {
  late NavisDatabase database;
  late _MockDownloadService service;

  setUp(() async {
    database = createTestDatabase();
    service = _MockDownloadService();
    when(
      () => service.enqueueSongs(
        any(),
        quality: any(named: 'quality'),
        format: any(named: 'format'),
      ),
    ).thenAnswer((_) async => 0);
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      SongsTableCompanion.insert(
        id: 'liked',
        title: 'Liked',
        starred: Value(DateTime(2026)),
      ),
    ]);
  });

  tearDown(() => database.close());

  Future<ProviderContainer> dispatch({bool flippableNetwork = false}) async {
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
            OnlineReachability.new,
          ),
          if (!flippableNetwork)
            networkTypeProvider.overrideWithValue(NetworkType.wifi)
          else
            networkTypeProvider.overrideWith(
              (ref) => ref.watch(_testNetworkProvider),
            ),
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
    return container;
  }

  test('liked songs download in the saved quality on Wi-Fi', () async {
    await database.appSettingsDao.updateDownloadQuality(
      mode: DownloadQualityMode.transcode,
      bitRate: 256,
      format: 'aac',
    );
    await dispatch();
    verify(() => service.enqueueSongs(['liked'], quality: '256', format: 'aac'))
        .called(1);
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'with no saved quality, liked songs download in original quality',
    () async {
      await dispatch();
      verify(() => service.enqueueSongs(['liked'])).called(1);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );

  test('a large liked library queues in one batch, never per song', () async {
    await database.libraryDao.upsertSongs(<SongsTableCompanion>[
      for (var i = 0; i < 500; i++)
        SongsTableCompanion.insert(
          id: 'bulk-$i',
          title: 'Bulk $i',
          starred: Value(DateTime(2026)),
        ),
    ]);
    await dispatch();
    final ids =
        verify(
              () => service.enqueueSongs(
                captureAny(),
                quality: any(named: 'quality'),
                format: any(named: 'format'),
              ),
            ).captured.single
            as List<String>;
    expect(ids, hasLength(501));
    expect(ids.toSet(), hasLength(501));
    verifyNever(
      () => service.enqueueSong(
        any(),
        quality: any(named: 'quality'),
        format: any(named: 'format'),
      ),
    );
  }, skip: sqliteAvailable ? null : 'sqlite3 not available');

  test(
    'a network flip while dispatching does not enqueue a second time',
    () async {
      final release = Completer<int>();
      when(
        () => service.enqueueSongs(
          any(),
          quality: any(named: 'quality'),
          format: any(named: 'format'),
        ),
      ).thenAnswer((_) => release.future);
      final container = await dispatch(flippableNetwork: true);
      // The connection drops and returns while the first dispatch is still
      // running.
      container.read(_testNetworkProvider.notifier).set(NetworkType.offline);
      await Future<void>.delayed(Duration.zero);
      container.read(_testNetworkProvider.notifier).set(NetworkType.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      release.complete(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      verify(
        () => service.enqueueSongs(
          any(),
          quality: any(named: 'quality'),
          format: any(named: 'format'),
        ),
      ).called(1);
    },
    skip: sqliteAvailable ? null : 'sqlite3 not available',
  );
}
