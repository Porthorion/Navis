import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../helpers/test_database.dart';

class _TrackingDio extends DioForNative {
  new(super.baseOptions);

  bool closed = false;

  @override
  void close({bool force = false}) {
    closed = true;
    super.close(force: force);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'provider disposal closes artwork Dio before service teardown awaits',
    () async {
      final db = createTestDatabase();
      final clients = <_TrackingDio>[];
      final container = ProviderContainer(
        overrides: withTestDatabase(
          db,
          overrides: [
            networkTypeProvider.overrideWith((_) => NetworkType.offline),
            subsonicApiProvider.overrideWithValue(null),
            playerStateProvider.overrideWithValue(
              const PlaybackSnapshot.idle(),
            ),
            externalDioFactoryProvider.overrideWithValue((service, {options}) {
              final dio = _TrackingDio(options);
              clients.add(dio);
              return dio;
            }),
          ],
        ),
      );
      final service = container.read(downloadServiceProvider);
      // The artwork transport is created before the shared Deezer API client.
      final artworkDio = clients.first;
      await service.stopAndWait();
      addTearDown(() async {
        for (final dio in clients) {
          dio.close(force: true);
        }
        await service.dispose();
        await db.close();
      });
      container.dispose();
      expect(artworkDio.closed, isTrue);
    },
    skip: !sqliteAvailable,
  );
}
