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
      'missing secure password clears stale drift session',
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
        final rowAfter = await database.serverDao.getActiveServer();

        expect(config, isNull);
        expect(rowAfter, isNull);
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
      'getActiveServer clears stale drift row when secure read fails',
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
        final rowAfter = await database.serverDao.getActiveServer();
        expect(config, isNull);
        expect(rowAfter, isNull);
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
  });
}
