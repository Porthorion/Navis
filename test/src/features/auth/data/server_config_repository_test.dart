import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import '../../../../helpers/test_database.dart';

class _FakeCredentialStore implements SecureCredentialStore {
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

class _ThrowingCredentialStore implements SecureCredentialStore {
  _ThrowingCredentialStore({
    this.throwOnRead = false,
    this.throwOnClear = false,
  });

  final bool throwOnRead;
  final bool throwOnClear;

  @override
  Future<void> clearPassword() async {
    if (throwOnClear) {
      throw StateError('clear failed');
    }
  }

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

  group('ServerConfigRepository', () {
    late NavisDatabase database;
    late _FakeCredentialStore credentials;
    late ServerConfigRepository repository;

    setUp(() {
      database = NavisDatabase(NativeDatabase.memory());
      credentials = _FakeCredentialStore();
      repository = ServerConfigRepository(database, credentials: credentials);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'save writes drift metadata and secure password',
      () async {
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
      },
      skip: !sqliteAvailable,
    );

    test(
      'getActiveServer combines drift row with secure password',
      () async {
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
      },
      skip: !sqliteAvailable,
    );

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

    test(
      'getActiveServer tolerates secure credential clear failure',
      () async {
        repository = ServerConfigRepository(
          database,
          credentials: _ThrowingCredentialStore(throwOnClear: true),
        );

        final config = await repository.getActiveServer();
        expect(config, isNull);
      },
      skip: !sqliteAvailable,
    );

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

    test(
      'updateSyncTimestamps updates last full sync timestamp',
      () async {
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
      },
      skip: !sqliteAvailable,
    );

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
