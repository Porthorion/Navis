import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:path/path.dart' as p;

import '../../../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final raw in ['{', '[1]', 'github', '"github"', '["deezer"]']) {
    test(
      'malformed or unrelated integration JSON defaults to Porthorion: $raw',
      () {
        expect(
          UpdateSource.fromIntegrationSettings(raw),
          UpdateSource.porthorion,
        );
      },
    );
  }

  test('source persists across database and provider restart beside integration switches', () async {
    final temp = await Directory.systemTemp.createTemp('update_source_test_');
    addTearDown(() => temp.delete(recursive: true));
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => temp.path);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(paths, null),
    );
    final file = File(p.join(temp.path, 'settings.sqlite'));
    var database = createTestDatabase(file: file);
    var container = ProviderContainer(overrides: withTestDatabase(database));
    container.listen(appSettingsProvider, (_, _) {});
    container.listen(updateSourceProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    expect(container.read(updateSourceProvider), UpdateSource.porthorion);
    await container.read(updateCheckStoreProvider).recordCheck();
    await container.read(updateCheckStoreProvider).recordVerifiedManifest({
      'payload': 'old',
      'signature': 'old',
    });
    await container
        .read(updateSourceProvider.notifier)
        .setSource(UpdateSource.github);
    expect(
      await container.read(updateCheckStoreProvider).readVerifiedManifest(),
      isNull,
    );
    expect(
      await container.read(updateCheckStoreProvider).shouldCheck(),
      isTrue,
    );
    await database.appSettingsDao.setIntegrationEnabled(
      'deezer',
      enabled: false,
    );
    container.dispose();
    await database.close();
    database = createTestDatabase(file: file);
    container = ProviderContainer(overrides: withTestDatabase(database));
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    container.listen(appSettingsProvider, (_, _) {});
    container.listen(updateSourceProvider, (_, _) {});
    await container.read(appSettingsProvider.future);
    expect(container.read(updateSourceProvider), UpdateSource.github);
    expect(
      (await SettingsRepository(
        database.appSettingsDao,
      ).getSettings()).disabledIntegrations,
      contains('deezer'),
    );
    expect(container.read(effectiveUpdateSourceProvider), UpdateSource.github);
    expect(container.read(updateHostProvider), 'github.com');
    await container
        .read(updateSourceProvider.notifier)
        .setSource(UpdateSource.porthorion);
    expect(
      UpdateSource.fromIntegrationSettings(
        (await SettingsRepository(
          database.appSettingsDao,
        ).getSettings()).disabledIntegrations,
      ),
      UpdateSource.porthorion,
    );
  }, skip: !sqliteAvailable);
}
