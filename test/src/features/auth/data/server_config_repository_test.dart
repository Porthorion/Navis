import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/secure_credential_store.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:sqlite3/sqlite3.dart';

bool get _sqliteAvailable {
  try {
    final db = sqlite3.openInMemory();
    db.dispose();
    return true;
  } on Object {
    return false;
  }
}

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
    }, skip: !_sqliteAvailable);

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
      skip: !_sqliteAvailable,
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
      skip: !_sqliteAvailable,
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
    }, skip: !_sqliteAvailable);
  });
}
