import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';

import '../../../../helpers/test_database.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage;

class _FakeCredentialStore implements ServerUrlCredentialStore {
  String? userInfo;
  int userInfoSaves = 0;

  @override
  Future<void> saveUserInfo(String value) async {
    userInfoSaves++;
    userInfo = value;
  }

  @override
  Future<String?> readUserInfo() async => userInfo;

  @override
  Future<void> clearUserInfo() async => userInfo = null;
  String? password;
  int clearCalls = 0;

  @override
  Future<void> clearPassword() async {
    clearCalls++;
    password = null;
  }

  @override
  Future<String?> readPassword() async => password;

  @override
  Future<void> savePassword(String password) async {
    this.password = password;
  }
}

/// Runs [onSaved] right after the password is stored, like another reader of
/// the active server landing between save()'s two writes.
class _ReadDuringSaveCredentialStore extends _FakeCredentialStore {
  Future<void> Function()? onSaved;

  @override
  Future<void> savePassword(String password) async {
    await super.savePassword(password);
    await onSaved?.call();
  }
}

class _ThrowingCredentialStore implements SecureCredentialStore {
  new({this.throwOnRead = false});

  final bool throwOnRead;

  @override
  Future<void> clearPassword() async {}

  @override
  Future<String?> readPassword() async {
    if (throwOnRead) {
      throw StateError('read failed');
    }
    return null;
  }

  @override
  Future<void> savePassword(String password) async {}
}

void main() {
  test(
    'clone diagnostics credential clear never mutates backing storage',
    () async {
      final backing = _FakeCredentialStore()..password = 'real-secret';
      final clone = CloneDiagnosticsCredentialStore(backing);

      expect(await clone.readPassword(), 'real-secret');
      await clone.clearPassword();

      expect(await clone.readPassword(), isNull);
      expect(backing.password, 'real-secret');
      expect(backing.clearCalls, 0);
    },
  );

  test(
    'clone diagnostics can seed its isolated credential from a file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'navis-clone-credentials-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final credentialFile = File('${directory.path}/password')
        ..writeAsStringSync('fixture-secret\n');
      final backing = _FakeCredentialStore()..password = 'real-secret';
      final clone = CloneDiagnosticsCredentialStore(
        backing,
        credentialPath: credentialFile.path,
      );

      expect(await clone.readPassword(), 'fixture-secret');
      await clone.clearPassword();

      expect(await clone.readPassword(), isNull);
      expect(backing.password, 'real-secret');
      expect(backing.clearCalls, 0);
    },
  );

  test('clone diagnostics shares one concurrent credential load', () async {
    final backing = _FakeCredentialStore()..password = 'fixture-secret';
    final clone = CloneDiagnosticsCredentialStore(backing);

    final values = await Future.wait([
      clone.readPassword(),
      clone.readPassword(),
    ]);

    expect(values, everyElement('fixture-secret'));
  });

  test('URL secure storage failure uses memory only and clears it', () async {
    final storage = _MockSecureStorage();
    when(
      () => storage.write(
        key: any(named: 'key'),
        value: any(named: 'value'),
      ),
    ).thenThrow(StateError('unavailable'));
    when(() => storage.read(key: any(named: 'key')))
        .thenThrow(StateError('unavailable'));
    when(() => storage.delete(key: any(named: 'key')))
        .thenThrow(StateError('unavailable'));
    final store = FlutterSecureCredentialStore(storage: storage);
    await store.saveUserInfo('proxy:fixture');
    expect(await store.readUserInfo(), 'proxy:fixture');
    await store.clearUserInfo();
    expect(await store.readUserInfo(), isNull);
    verify(
      () => storage.write(
        key: 'navis.auth.active_server.user_info',
        value: 'proxy:fixture',
      ),
    ).called(1);
  });

  group('ServerConfigRepository', () {
    late NavisDatabase database;
    late _FakeCredentialStore credentials;
    late ServerConfigRepository repository;

    setUp(() {
      database = createTestDatabase();
      credentials = _FakeCredentialStore();
      repository = ServerConfigRepository(database, credentials: credentials);
    });

    tearDown(() async {
      await database.close();
    });

    const proxyConfig = ServerConfigModel(
      url: 'https://proxy:p%40ss@example.com/music',
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
    );

    test(
      'URL credentials live only in secure storage and the loaded model',
      () async {
        await repository.save(proxyConfig);
        expect(
          (await database.serverDao.getActiveServer())?.url,
          'https://example.com/music',
        );
        expect(credentials.userInfo, 'proxy:p%40ss');
        expect((await repository.getActiveServer())?.url, proxyConfig.url);
        expect(
          (await repository.watchActiveServer().first)?.url,
          proxyConfig.url,
        );
        expect(
          await repository.compareRetainedServer(proxyConfig),
          RetainedServerMatch.same,
        );
        await repository.save(
          proxyConfig.copyWith(url: 'https://new:proxy@example.com/music'),
        );
        expect(credentials.userInfo, 'new:proxy');
      },
      skip: !sqliteAvailable,
    );

    test(
      'load migrates legacy URL once, preserving transport credentials',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            url: proxyConfig.url,
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
        credentials.password = 'secret';
        expect((await repository.getActiveServer())?.url, proxyConfig.url);
        expect(
          (await database.serverDao.getActiveServer())?.url,
          'https://example.com/music',
        );
        expect((await repository.getActiveServer())?.url, proxyConfig.url);
        expect(credentials.userInfoSaves, 1);
      },
      skip: !sqliteAvailable,
    );

    for (final wipe in [false, true]) {
      test('sign-out wipes URL credentials (wipe: $wipe)', () async {
        await repository.save(proxyConfig);
        if (wipe) {
          await repository.clear();
        } else {
          await repository.signOutKeepData();
          expect(
            (await repository.getRetainedServer())?.url,
            'https://example.com/music',
          );
        }
        expect(credentials.userInfo, isNull);
        expect(credentials.password, isNull);
      }, skip: !sqliteAvailable);
    }

    test(
      'signed-out legacy profile is scrubbed without resurrecting credentials',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            url: proxyConfig.url,
            username: 'alice',
            apiVersion: '1.16.1',
            isAuthenticated: const Value(false),
          ),
        );
        expect(await repository.getActiveServer(), isNull);
        expect(
          (await database.serverDao.getRetainedServer())?.url,
          'https://example.com/music',
        );
        expect(credentials.userInfo, isNull);
      },
      skip: !sqliteAvailable,
    );

    test('save writes drift metadata and secure password', () async {
      await repository.save(
        const ServerConfigModel(
          name: 'example.com',
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );

      final row = await database.serverDao.getActiveServer();
      expect(row?.url, 'https://example.com');
      expect(row?.username, 'alice');
      expect(credentials.password, 'secret');
    }, skip: !sqliteAvailable);

    test('getActiveServer combines drift row with secure password', () async {
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          name: Value('example.com'),
          url: 'https://example.com',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      credentials.password = 'secret';

      final config = await repository.getActiveServer();
      expect(config, isNotNull);
      expect(config?.password, 'secret');
      expect(config?.username, 'alice');
    }, skip: !sqliteAvailable);

    test(
      'missing secure password signs out without deleting retained profile',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            name: Value('example.com'),
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
        credentials.password = null;

        final config = await repository.getActiveServer();
        final activeAfter = await database.serverDao.getActiveServer();
        final retainedAfter = await database.serverDao.getRetainedServer();

        expect(config, isNull);
        expect(activeAfter, isNull);
        expect(retainedAfter, isNotNull);
        expect(retainedAfter?.username, 'alice');
        expect(retainedAfter?.isAuthenticated, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'reading while signed out keeps a password saved for the next sign-in',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            name: Value('example.com'),
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
        await database.serverDao.markSignedOut();
        // save() stores the password before it marks the row authenticated.
        credentials.password = 'new-secret';

        final config = await repository.getActiveServer();

        expect(config, isNull);
        expect(credentials.password, 'new-secret');
        expect(credentials.clearCalls, 0);
      },
      skip: !sqliteAvailable,
    );

    test(
      'sign-in after a keep-data sign-out survives a concurrent read',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            name: Value('example.com'),
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
        await database.serverDao.markSignedOut();
        final racing = _ReadDuringSaveCredentialStore();
        repository = ServerConfigRepository(database, credentials: racing);
        racing.onSaved = repository.getActiveServer;

        await repository.save(
          const ServerConfigModel(
            name: 'example.com',
            url: 'https://example.com',
            username: 'alice',
            password: 'new-secret',
            apiVersion: '1.16.1',
          ),
        );
        final config = await repository.getActiveServer();

        expect(config?.password, 'new-secret');
        expect(racing.password, 'new-secret');
      },
      skip: !sqliteAvailable,
    );

    test('clear removes both drift row and secure password', () async {
      await database.serverDao.saveServer(
        ServerConfigTableCompanion.insert(
          name: Value('example.com'),
          url: 'https://example.com',
          username: 'alice',
          apiVersion: '1.16.1',
        ),
      );
      credentials.password = 'secret';

      await repository.clear();

      final row = await database.serverDao.getActiveServer();
      expect(row, isNull);
      expect(credentials.password, isNull);
      expect(credentials.clearCalls, 1);
    }, skip: !sqliteAvailable);

    test('getActiveServer without a server row leaves credentials', () async {
      credentials.password = 'secret';

      final config = await repository.getActiveServer();

      expect(config, isNull);
      expect(credentials.password, 'secret');
      expect(credentials.clearCalls, 0);
    }, skip: !sqliteAvailable);

    test(
      'getActiveServer signs out retained row when secure read fails',
      () async {
        await database.serverDao.saveServer(
          ServerConfigTableCompanion.insert(
            name: Value('example.com'),
            url: 'https://example.com',
            username: 'alice',
            apiVersion: '1.16.1',
          ),
        );
        repository = ServerConfigRepository(
          database,
          credentials: _ThrowingCredentialStore(throwOnRead: true),
        );

        final config = await repository.getActiveServer();
        final rowAfter = await database.serverDao.getRetainedServer();
        expect(config, isNull);
        expect(rowAfter, isNotNull);
        expect(rowAfter?.isAuthenticated, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test('updateLastSynced updates sync timestamp only', () async {
      await repository.save(
        const ServerConfigModel(
          name: 'example.com',
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );
      final before = await repository.getActiveServer();
      final syncedAt = DateTime.now();

      await repository.updateLastSynced(syncedAt);
      final after = await repository.getActiveServer();

      expect(after, isNotNull);
      expect(after?.url, before?.url);
      expect(after?.username, before?.username);
      expect(after?.password, before?.password);
      final difference = after?.lastSynced?.difference(syncedAt);
      expect(difference, isNotNull);
      expect(difference!.inSeconds.abs(), lessThanOrEqualTo(1));
    }, skip: !sqliteAvailable);

    test('updateSyncTimestamps updates last full sync timestamp', () async {
      await repository.save(
        const ServerConfigModel(
          name: 'example.com',
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );
      final syncedAt = DateTime.now();
      final fullSyncedAt = syncedAt.subtract(const Duration(minutes: 1));

      await repository.updateSyncTimestamps(
        lastSynced: syncedAt,
        lastFullSyncedAt: fullSyncedAt,
      );
      final after = await repository.getActiveServer();

      expect(after, isNotNull);
      expect(after?.lastSynced, isNotNull);
      expect(after?.lastFullSyncedAt, isNotNull);
      expect(
        after?.lastFullSyncedAt?.difference(fullSyncedAt).inSeconds.abs(),
        lessThanOrEqualTo(1),
      );
    }, skip: !sqliteAvailable);

    test(
      'same-profile reauthentication preserves identity and sync state',
      () async {
        final syncedAt = DateTime(2026, 1, 2, 3, 4);
        await repository.save(
          ServerConfigModel(
            name: 'Old name',
            url: 'https://EXAMPLE.com/',
            username: 'alice',
            password: 'old-secret',
            apiVersion: '1.16.1',
            capabilitiesJson: '{"navis":{"plannerVersion":9},"scan":"old"}',
            lastSynced: syncedAt,
          ),
        );
        final before = await database.serverDao.getRetainedServer();
        await database.librarySyncDao.writeState(
          LibrarySyncStateTableCompanion(
            serverId: Value(before!.id),
            currentGeneration: const Value(7),
            safePageSize: const Value(321),
          ),
        );
        await repository.signOutKeepData();

        expect(
          await repository.compareRetainedServer(
            const ServerConfigModel(
              url: 'https://example.com:443',
              username: ' alice ',
              password: 'new-secret',
              apiVersion: '1.16.1',
            ),
          ),
          RetainedServerMatch.same,
        );
        await repository.save(
          const ServerConfigModel(
            name: 'Fresh name',
            url: 'https://example.com:443',
            username: ' alice ',
            password: 'new-secret',
            apiVersion: '1.16.1',
            capabilitiesJson: '{"navis":{"plannerVersion":1},"scan":"new"}',
          ),
        );

        final after = await database.serverDao.getActiveServer();
        final syncState = await database.librarySyncDao.getOrCreateState(
          after!.id,
        );
        expect(after.id, before.id);
        expect(after.lastSynced, syncedAt);
        expect(after.isAuthenticated, isTrue);
        expect(after.capabilities, contains('"plannerVersion":9'));
        expect(after.capabilities, contains('"scan":"new"'));
        expect(syncState.currentGeneration, 7);
        expect(syncState.safePageSize, 321);
        expect(credentials.password, 'new-secret');
      },
      skip: !sqliteAvailable,
    );

    test('different profile requires explicit deletion', () async {
      await repository.save(
        const ServerConfigModel(
          url: 'https://example.com',
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
      );
      await repository.signOutKeepData();
      const candidate = ServerConfigModel(
        url: 'https://example.com',
        username: 'bob',
        password: 'other-secret',
        apiVersion: '1.16.1',
      );

      expect(
        await repository.compareRetainedServer(candidate),
        RetainedServerMatch.different,
      );
      await expectLater(
        repository.save(candidate),
        throwsA(isA<RetainedServerMismatchException>()),
      );
      expect((await database.serverDao.getRetainedServer())?.username, 'alice');
      expect(credentials.password, isNull);

      await repository.clear();
      await repository.save(candidate);
      expect((await database.serverDao.getActiveServer())?.username, 'bob');
    }, skip: !sqliteAvailable);
  });
}
