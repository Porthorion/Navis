import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/features/downloads/data/permanent_artwork_store.dart';
import 'package:path/path.dart' as p;

class _MockDio extends Mock implements Dio;

void main() {
  late Directory support;
  late _MockDio dio;
  late List<int> body;
  final api = SubsonicApiClient(
    baseUrl: 'http://127.0.0.1:9',
    authConfig: const SubsonicAuthConfig(
      username: 'alice',
      password: 'secret',
      apiVersion: '1.16.1',
    ),
    enableLogging: false,
  );

  setUpAll(() {
    registerFallbackValue(Uri.parse('http://127.0.0.1:9/'));
    registerFallbackValue(Options());
  });

  setUp(() async {
    support = await Directory.systemTemp.createTemp('navis_artwork_');
    dio = _MockDio();
    body = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1];
    when(() => dio.getUri<List<int>>(any(), options: any(named: 'options')))
        .thenAnswer(
          (invocation) async => Response<List<int>>(
            requestOptions: RequestOptions(path: 'cover'),
            statusCode: 200,
            data: body,
          ),
        );
  });

  tearDown(() => support.delete(recursive: true));

  PermanentArtworkStore store() => PermanentArtworkStore(
    readApplicationSupportDirectory: () async => support,
    dio: dio,
  );

  test(
    'stores validated external bytes under server key and prunes by that key',
    () async {
      final artwork = store();
      expect(await artwork.storeBytes('album', [1, 2, 3]), isFalse);
      expect(await artwork.storeBytes('album', body), isTrue);
      await artwork.prune(['album']);
      expect(await store().fileFor('album'), isNotNull);
      verifyNever(
        () => dio.getUri<List<int>>(any(), options: any(named: 'options')),
      );
    },
  );

  test('only a missing response permits external fallback', () async {
    final artwork = store();
    body = [];
    expect(
      await artwork.ensureWithResult('empty', api),
      ArtworkEnsureResult.serverMissing,
    );
    when(() => dio.getUri<List<int>>(any(), options: any(named: 'options')))
        .thenThrow(
          DioException(
            requestOptions: RequestOptions(),
            response: Response<void>(
              requestOptions: RequestOptions(),
              statusCode: 503,
            ),
          ),
        );
    expect(
      await artwork.ensureWithResult('transient', api),
      ArtworkEnsureResult.failed,
    );
    when(() => dio.getUri<List<int>>(any(), options: any(named: 'options')))
        .thenThrow(
          DioException(
            requestOptions: RequestOptions(),
            response: Response<void>(
              requestOptions: RequestOptions(),
              statusCode: 404,
            ),
          ),
        );
    expect(
      await artwork.ensureWithResult('absent', api),
      ArtworkEnsureResult.serverMissing,
    );
  });

  test(
    'Subsonic missing-cover envelopes allow fallback but auth errors do not',
    () async {
      final artwork = store();
      body = '{"subsonic-response":{"status":"failed","error":{"code":70}}}'
          .codeUnits;
      expect(
        await artwork.ensureWithResult('missing-envelope', api),
        ArtworkEnsureResult.serverMissing,
      );
      body = '<subsonic-response status="failed"><error code="40"/></subsonic-response>'
          .codeUnits;
      expect(
        await artwork.ensureWithResult('auth-envelope', api),
        ArtworkEnsureResult.failed,
      );
    },
  );

  test('stores a cover once, named for its image type', () async {
    final artwork = store();
    expect(await artwork.ensure('al-1/x', api), isTrue);
    expect(await artwork.ensure('al-1/x', api), isTrue);

    final file = (await artwork.fileFor('al-1/x'))!;
    expect(p.basename(file.path), 'al-1_x.png');
    expect(file.readAsBytesSync(), body);
    final request =
        verify(
              () => dio.getUri<List<int>>(
                captureAny(),
                options: any(named: 'options'),
              ),
            ).captured.single
            as Uri;
    expect(
      request.queryParameters['size'],
      '${PermanentArtworkStore.artworkSize}',
    );
  });

  test('never stores a payload without an image signature', () async {
    body = '<subsonic-response status="failed"/>'.codeUnits;
    final artwork = store();
    expect(await artwork.ensure('al-2', api), isFalse);
    expect(await artwork.fileFor('al-2'), isNull);
    expect(
      Directory(p.join(support.path, 'artwork', 'permanent')).existsSync() &&
          Directory(p.join(support.path, 'artwork', 'permanent'))
              .listSync()
              .isNotEmpty,
      isFalse,
    );
  });

  test(
    'a new store finds covers saved earlier and prunes unused ones',
    () async {
      final first = store();
      await first.ensure('keep', api);
      await first.ensure('drop', api);

      final reopened = store();
      expect(await reopened.count(), 2);
      await reopened.prune(<String>['keep']);
      expect(await reopened.fileFor('keep'), isNotNull);
      expect(await reopened.fileFor('drop'), isNull);
      expect(
        Directory(p.join(support.path, 'artwork', 'permanent'))
            .listSync()
            .map((e) => p.basename(e.path)),
        <String>['keep.png'],
      );

      await reopened.clear();
      expect(await reopened.count(), 0);
    },
  );

  test('an unreadable support directory only means no stored covers', () async {
    final artwork = PermanentArtworkStore(
      readApplicationSupportDirectory: () async =>
          throw const FileSystemException('denied'),
      dio: dio,
    );
    expect(await artwork.fileFor('al-1'), isNull);
    expect(await artwork.count(), 0);
  });
}
