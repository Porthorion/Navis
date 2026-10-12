import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/provider_retry.dart';

class _Repository extends Mock implements ServerConfigRepository;

void main() {
  const config = ServerConfigModel(
    url: 'https://example.test',
    username: 'fixture',
    password: 'fixture',
    apiVersion: '1.16.1',
  );

  test('server config bootstrap retries transient credential reads', () async {
    final repository = _Repository();
    final changes = StreamController<ServerConfigModel?>.broadcast();
    addTearDown(changes.close);
    var watches = 0;
    when(repository.watchActiveServer).thenAnswer((_) {
      if (++watches == 1) {
        return Stream.error(const CredentialReadException());
      }
      return changes.stream;
    });
    var reads = 0;
    when(repository.getActiveServer).thenAnswer((_) async {
      if (++reads == 1) throw const CredentialReadException();
      return config;
    });
    final container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: [serverConfigRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    container.listen(serverConfigProvider, (_, _) {});

    expect(await container.read(serverConfigProvider.future), config);
    expect(reads, 2);
    expect(container.read(serverConfigProvider).value, config);
    changes.add(config.copyWith(name: 'Refreshed profile'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(serverConfigProvider).value?.name,
      'Refreshed profile',
    );
    verifyNever(repository.signOutKeepData);
    verifyNever(repository.clear);
  });

  test('refresh failure preserves the authenticated provider value', () async {
    final repository = _Repository();
    when(repository.watchActiveServer).thenAnswer((_) => const Stream.empty());
    when(repository.getActiveServer).thenAnswer((_) async => config);
    final container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: [serverConfigRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    expect(await container.read(serverConfigProvider.future), config);
    when(repository.getActiveServer).thenThrow(const CredentialReadException());

    await expectLater(
      container.read(serverConfigProvider.notifier).refresh(),
      throwsA(isA<CredentialReadException>()),
    );

    expect(container.read(serverConfigProvider).value, config);
    verifyNever(repository.signOutKeepData);
    verifyNever(repository.clear);
  });

  test(
    'credential stream errors are represented without signing out',
    () async {
      final repository = _Repository();
      final changes = StreamController<ServerConfigModel?>();
      addTearDown(changes.close);
      when(repository.watchActiveServer).thenAnswer((_) => changes.stream);
      when(repository.getActiveServer).thenAnswer((_) async => config);
      final container = ProviderContainer(
        retry: navisProviderRetry,
        overrides: [
          serverConfigRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(serverConfigProvider.future), config);

      changes.addError(const CredentialReadException());
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(serverConfigProvider).error,
        isA<CredentialReadException>(),
      );
      changes.add(config);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(serverConfigProvider).value, config);
      verifyNever(repository.signOutKeepData);
      verifyNever(repository.clear);
    },
  );
}
