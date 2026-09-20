import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/data/annotation_sync_dispatcher.dart';

import '../../../../helpers/test_database.dart';

Future<int> _runOtherConnection(String path) =>
    Isolate.run(() => _dispatchFromSeparateConnection(path));

Future<int> _dispatchFromSeparateConnection(String path) async {
  final database = createTestDatabase(file: File(path));
  final dio = Dio();
  var requests = 0;
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        requests++;
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: {
              'subsonic-response': {'status': 'ok'},
            },
          ),
        );
      },
    ),
  );
  final client = SubsonicApiClient(
    baseUrl: 'https://example.test',
    authConfig: const SubsonicAuthConfig(
      username: 'fixture',
      password: 'fixture',
      apiVersion: '1.16.1',
    ),
    dio: dio,
    enableLogging: false,
  );
  final writer = AnnotationSyncDispatcher(
    dao: database.starSyncDao,
    readClient: () => client,
    readAccountIdentity: () async => 'fixture-account',
    canConnect: () => true,
    now: () => DateTime.utc(2026, 9, 19),
  );
  try {
    await database.starSyncDao.setStarred(
      itemId: 's',
      itemType: 'song',
      liked: false,
    );
    await writer.flush();
    return requests;
  } finally {
    writer.dispose();
    dio.close(force: true);
    await database.close();
  }
}

void main() {
  late NavisDatabase db;
  late Dio dio;
  late SubsonicApiClient client;
  late AnnotationSyncDispatcher dispatcher;
  late DateTime now;
  String? account;
  final requests = <RequestOptions>[];
  Completer<void>? responseGate;
  int? errorCode;
  setUp(() async {
    db = createTestDatabase();
    await db.libraryDao.upsertSongs([
      SongsTableCompanion.insert(id: 's', title: 'Song'),
    ]);
    now = DateTime.utc(2026, 9, 19);
    account = 'fixture-account';
    requests.clear();
    responseGate = null;
    errorCode = null;
    dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          requests.add(options);
          await responseGate?.future;
          handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'subsonic-response': errorCode == null
                    ? {'status': 'ok'}
                    : {
                        'status': 'failed',
                        'error': {
                          'code': errorCode,
                          'message': 'Fixture error',
                        },
                      },
              },
            ),
          );
        },
      ),
    );
    client = SubsonicApiClient(
      baseUrl: 'https://example.test',
      authConfig: const SubsonicAuthConfig(
        username: 'fixture',
        password: 'fixture',
        apiVersion: '1.16.1',
      ),
      dio: dio,
      enableLogging: false,
    );
    dispatcher = AnnotationSyncDispatcher(
      dao: db.starSyncDao,
      readClient: () => client,
      readAccountIdentity: () async => account,
      canConnect: () => true,
      now: () => now,
    );
  });
  tearDown(() async {
    dispatcher.dispose();
    dio.close(force: true);
    await db.close();
  });

  test('another database owner blocks dispatch and cannot be acknowledged by stale owner', () async {
    await db.starSyncDao.setStarred(itemId: 's', itemType: 'song', liked: true);
    expect(
      await db.starSyncDao.acquireDispatchLease('other-process', now),
      isTrue,
    );
    await dispatcher.flush();
    expect(requests, isEmpty);
    expect(await db.starSyncDao.getPendingActions(), hasLength(1));
    now = now.add(const Duration(minutes: 2));
    await dispatcher.flush();
    expect(requests, hasLength(1));
    expect(await db.starSyncDao.getPendingActions(), isEmpty);
    expect(await db.starSyncDao.acquireDispatchLease('new-owner', now), isTrue);
    var acknowledged = false;
    expect(
      await db.starSyncDao.withDispatchLease('other-process', now, () async {
        acknowledged = true;
      }),
      isFalse,
    );
    expect(acknowledged, isFalse);
  });

  test(
    'two isolate connections serialize annotation network writers',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'navis-annotation-lease-',
      );
      final databasePath = '${directory.path}/fixture.sqlite';
      await db.close();
      db = createTestDatabase(file: File(databasePath));
      await db.libraryDao.upsertSongs([
        SongsTableCompanion.insert(id: 's', title: 'Song'),
      ]);
      final writer = AnnotationSyncDispatcher(
        dao: db.starSyncDao,
        readClient: () => client,
        readAccountIdentity: () async => account,
        canConnect: () => true,
        now: () => now,
      );
      try {
        await db.starSyncDao.setStarred(
          itemId: 's',
          itemType: 'song',
          liked: true,
        );
        responseGate = Completer<void>();
        final delivery = writer.flush();
        while (requests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final otherRequests = await _runOtherConnection(databasePath);
        expect(otherRequests, 0);
        expect(requests, hasLength(1));
        responseGate!.complete();
        await delivery;
        expect(requests.map((request) => request.path), [
          '/rest/star.view',
          '/rest/unstar.view',
        ]);
        expect(await db.starSyncDao.getPendingActions(), isEmpty);
        expect(await db.libraryDao.getSongStarred('s'), isNull);
      } finally {
        writer.dispose();
        await db.close();
        db = createTestDatabase();
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('concurrent toggles serialize the read and durable write', () async {
    final results = await Future.wait([
      db.starSyncDao.toggleSongStarred('s'),
      db.starSyncDao.toggleSongStarred('s'),
    ]);
    expect(results, [true, false]);
    expect(await db.libraryDao.getSongStarred('s'), isNull);
    expect((await db.starSyncDao.getPendingActions()).single.action, 'unstar');
  });

  test(
    'star and rating commit independently and deliver through one writer',
    () async {
      await db.starSyncDao.setStarred(
        itemId: 's',
        itemType: 'song',
        liked: true,
      );
      await db.starSyncDao.setRating(itemId: 's', itemType: 'song', rating: 4);
      expect(await db.starSyncDao.getPendingActions(), hasLength(2));
      expect((await db.libraryDao.getSongById('s'))?.userRating, 4);
      await Future.wait([
        dispatcher.flush(),
        dispatcher.flush(),
        dispatcher.flush(),
      ]);
      expect(requests.map((request) => request.path), [
        '/rest/star.view',
        '/rest/setRating.view',
      ]);
      expect(await db.starSyncDao.getPendingActions(), isEmpty);
    },
  );

  test('older acknowledgement cannot remove a newer opposite intent', () async {
    await db.starSyncDao.setStarred(itemId: 's', itemType: 'song', liked: true);
    responseGate = Completer<void>();
    final first = dispatcher.flush();
    while (requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await db.starSyncDao.setStarred(
      itemId: 's',
      itemType: 'song',
      liked: false,
    );
    final concurrent = dispatcher.flush();
    expect(requests, hasLength(1));
    responseGate!.complete();
    await Future.wait([first, concurrent]);
    expect(requests.map((request) => request.path), [
      '/rest/star.view',
      '/rest/unstar.view',
    ]);
    expect((await db.libraryDao.getSongById('s'))?.starred, isNull);
    expect(await db.starSyncDao.getPendingActions(), isEmpty);
  });

  test('server errors retain intent and retry after durable backoff', () async {
    await db.starSyncDao.setRating(itemId: 's', itemType: 'song', rating: 5);
    errorCode = 0;
    await dispatcher.flush();
    final failed = (await db.starSyncDao.getPendingActions()).single;
    expect(failed.attemptCount, 1);
    expect(failed.notBefore?.toUtc(), now.add(const Duration(seconds: 15)));
    errorCode = null;
    await dispatcher.flush();
    expect(requests, hasLength(1));
    now = now.add(const Duration(seconds: 16));
    await dispatcher.flush();
    expect(requests, hasLength(2));
    expect(await db.starSyncDao.getPendingActions(), isEmpty);
  });

  test(
    'reauthentication releases blocked intent without deleting it',
    () async {
      await db.starSyncDao.setStarred(
        itemId: 's',
        itemType: 'song',
        liked: true,
      );
      errorCode = 40;
      await dispatcher.flush();
      expect(
        (await db.starSyncDao.getPendingActions()).single.lastErrorType,
        'authentication',
      );
      errorCode = null;
      await dispatcher.sessionChanged();
      expect(await db.starSyncDao.getPendingActions(), isEmpty);
    },
  );

  test(
    'changed account prevents acknowledgement of the old account queue',
    () async {
      await db.starSyncDao.setStarred(
        itemId: 's',
        itemType: 'song',
        liked: true,
      );
      responseGate = Completer<void>();
      final pending = dispatcher.flush();
      while (requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      account = null;
      responseGate!.complete();
      await pending;
      expect(await db.starSyncDao.getPendingActions(), hasLength(1));
    },
  );
}
