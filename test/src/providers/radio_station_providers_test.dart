import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/api/models/internet_radio_station.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../helpers/test_database.dart';

class _MockApi extends Mock implements SubsonicApiClient;

void main() {
  test('admin status is false without an API', () async {
    final container = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    expect(await container.read(serverUserIsAdminProvider.future), isFalse);
  });

  for (final role in [true, false]) {
    test('admin status uses the API username and returns $role', () async {
      final api = _MockApi();
      when(() => api.authConfig).thenReturn(
        const SubsonicAuthConfig(
          username: 'alice',
          password: 'test',
          apiVersion: '1.16.1',
        ),
      );
      when(() => api.getUserIsAdmin('alice')).thenAnswer((_) async => role);
      final container = ProviderContainer(
        overrides: [subsonicApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      expect(await container.read(serverUserIsAdminProvider.future), role);
      verify(() => api.getUserIsAdmin('alice')).called(1);
    });
  }

  test('admin lookup errors return false', () async {
    final api = _MockApi();
    when(() => api.authConfig).thenReturn(
      const SubsonicAuthConfig(
        username: 'alice',
        password: 'test',
        apiVersion: '1.16.1',
      ),
    );
    when(() => api.getUserIsAdmin('alice'))
        .thenAnswer((_) async => throw StateError('unavailable'));
    final container = ProviderContainer(
      overrides: [subsonicApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    expect(await container.read(serverUserIsAdminProvider.future), isFalse);
    verify(() => api.getUserIsAdmin('alice')).called(1);
  });

  test('local provider maps DAO rows without a server connection', () async {
    final database = createTestDatabase();
    addTearDown(database.close);
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [subsonicApiProvider.overrideWithValue(null)],
      ),
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      localRadioStationsProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    final id = await database.localRadioStationDao.upsert(
      name: 'Station',
      streamUrl: 'https://radio.example/stream',
      homePageUrl: 'https://radio.example',
    );
    expect(await container.read(localRadioStationsProvider.future), [
      InternetRadioStation(
        id: id,
        name: 'Station',
        streamUrl: 'https://radio.example/stream',
        homePageUrl: 'https://radio.example',
      ),
    ]);
  }, skip: !sqliteAvailable);
}
