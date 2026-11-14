import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/data/sign_out_service.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/library/domain/library_sync_state.dart';
import 'package:navis/src/features/library/presentation/library_sync_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/providers/provider_retry.dart';
import 'package:navis/src/utils/connectivity.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

class _Repository extends Mock implements ServerConfigRepository;

class _PendingSignOut implements SignOutService {
  final pending = Completer<void>();

  @override
  Future<void> get pendingSignOut => pending.future;

  @override
  Future<void> signOut({required bool wipeLocalData}) async {}
}

/// Counts the sign-in catch-up requests without building the real controller.
class _CatchUpSpy extends LibrarySyncController {
  static int catchUps = 0;
  static bool Function()? isSaved;
  static bool? savedAtCall;

  @override
  LibrarySyncState build() => const LibrarySyncState.idle();

  @override
  void catchUpAfterSignIn() {
    catchUps++;
    savedAtCall = isSaved?.call();
  }
}

class _NetworkUsageMeter extends Mock implements NetworkUsageMeter;

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

  test('credential stream errors preserve the authenticated session and API client', () async {
    final repository = _Repository();
    final changes = StreamController<ServerConfigModel?>();
    addTearDown(changes.close);
    when(repository.watchActiveServer).thenAnswer((_) => changes.stream);
    when(repository.getActiveServer).thenAnswer((_) async => config);
    final container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: [
        serverConfigRepositoryProvider.overrideWithValue(repository),
        networkTypeProvider.overrideWithValue(NetworkType.wifi),
        networkUsageMeterProvider.overrideWithValue(_NetworkUsageMeter()),
      ],
    );
    addTearDown(container.dispose);
    expect(await container.read(serverConfigProvider.future), config);
    final activeState = container.read(serverConfigProvider);
    final client = container.read(subsonicApiProvider);
    expect(client, isNotNull);

    changes.addError(const CredentialReadException());
    await Future<void>.delayed(Duration.zero);
    expect(container.read(serverConfigProvider), same(activeState));
    expect(container.read(subsonicApiProvider), same(client));
    expect(await container.read(serverConfigProvider.future), config);
    changes.add(config.copyWith(name: 'Refreshed profile'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(serverConfigProvider).value?.name,
      'Refreshed profile',
    );
    changes.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(serverConfigProvider),
      const AsyncData<ServerConfigModel?>(null),
    );
    expect(container.read(subsonicApiProvider), isNull);
    verifyNever(repository.signOutKeepData);
    verifyNever(repository.clear);
  });

  test('non-credential stream errors still reach the error state', () async {
    final repository = _Repository();
    final changes = StreamController<ServerConfigModel?>();
    addTearDown(changes.close);
    when(repository.watchActiveServer).thenAnswer((_) => changes.stream);
    when(repository.getActiveServer).thenAnswer((_) async => config);
    final container = ProviderContainer(
      retry: navisProviderRetry,
      overrides: [serverConfigRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    await container.read(serverConfigProvider.future);
    final error = StateError('fixture database failure');

    changes.addError(error);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(serverConfigProvider).error, same(error));
  });

  test('saving credentials waits for a sign-out still running', () async {
    final repository = _Repository();
    final signOut = _PendingSignOut();
    when(repository.watchActiveServer).thenAnswer((_) => const Stream.empty());
    when(repository.getActiveServer).thenAnswer((_) async => null);
    when(() => repository.save(config)).thenAnswer((_) async {});
    when(() => repository.compareRetainedServer(config))
        .thenAnswer((_) async => RetainedServerMatch.none);
    final container = ProviderContainer(
      overrides: [
        serverConfigRepositoryProvider.overrideWithValue(repository),
        signOutServiceProvider.overrideWithValue(signOut),
      ],
    );
    addTearDown(container.dispose);
    container.listen(serverConfigProvider, (_, _) {});
    await container.read(serverConfigProvider.future);

    final saved = container.read(serverConfigProvider.notifier).save(config);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    verifyNever(() => repository.save(config));

    signOut.pending.complete();
    await saved;
    verify(() => repository.save(config)).called(1);
  });

  for (final (match, expected) in [
    (RetainedServerMatch.same, 1),
    (RetainedServerMatch.none, 0),
  ]) {
    test(
      'saving over a $match retained profile requests $expected catch-ups',
      () async {
        _CatchUpSpy.catchUps = 0;
        final repository = _Repository();
        when(repository.watchActiveServer)
            .thenAnswer((_) => const Stream.empty());
        when(repository.getActiveServer).thenAnswer((_) async => config);
        when(() => repository.save(config)).thenAnswer((_) async {});
        when(() => repository.compareRetainedServer(config))
            .thenAnswer((_) async => match);
        final container = ProviderContainer(
          overrides: [
            serverConfigRepositoryProvider.overrideWithValue(repository),
            signOutServiceProvider.overrideWithValue(
              _PendingSignOut()..pending.complete(),
            ),
            librarySyncControllerProvider.overrideWith(_CatchUpSpy.new),
          ],
        );
        addTearDown(container.dispose);
        container.listen(serverConfigProvider, (_, _) {});
        await container.read(serverConfigProvider.future);

        await container.read(serverConfigProvider.notifier).save(config);

        expect(_CatchUpSpy.catchUps, expected);
      },
    );
  }

  test('the catch-up intent is recorded before the row is saved', () async {
    _CatchUpSpy.catchUps = 0;
    var saved = false;
    _CatchUpSpy.isSaved = () => saved;
    addTearDown(() => _CatchUpSpy.isSaved = null);
    final repository = _Repository();
    when(repository.watchActiveServer).thenAnswer((_) => const Stream.empty());
    when(repository.getActiveServer).thenAnswer((_) async => config);
    when(() => repository.save(config)).thenAnswer((_) async => saved = true);
    when(() => repository.compareRetainedServer(config))
        .thenAnswer((_) async => RetainedServerMatch.same);
    final container = ProviderContainer(
      overrides: [
        serverConfigRepositoryProvider.overrideWithValue(repository),
        signOutServiceProvider.overrideWithValue(
          _PendingSignOut()..pending.complete(),
        ),
        librarySyncControllerProvider.overrideWith(_CatchUpSpy.new),
      ],
    );
    addTearDown(container.dispose);
    container.listen(serverConfigProvider, (_, _) {});
    await container.read(serverConfigProvider.future);

    await container.read(serverConfigProvider.notifier).save(config);

    expect(_CatchUpSpy.catchUps, 1);
    expect(_CatchUpSpy.savedAtCall, isFalse);
  });
}
