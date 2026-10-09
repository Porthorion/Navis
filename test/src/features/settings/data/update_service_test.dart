import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:path/path.dart' as p;

class _ArtifactAdapter implements HttpClientAdapter {
  new(this.bytes);
  final List<int> bytes;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentLengthHeader: ['${bytes.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  const url = '${AppConstants.updateBaseUrl}releases/v1.5.1/navis.zip';
  final bytes = List<int>.generate(123, (i) => i);
  late Directory temp;
  late _ArtifactAdapter adapter;
  late Dio dio;
  late UpdateService service;

  UpdateInfo info({String? downloadUrl, String? hash, int? size}) => UpdateInfo(
    tagName: 'v1.5.1',
    htmlUrl: AppConstants.updateManualDownloadUrl,
    delivery: UpdateDelivery.desktopSelfUpdate,
    downloadUrl: downloadUrl ?? url,
    assetFileName: 'navis.zip',
    sha256: hash ?? crypto.sha256.convert(bytes).toString(),
    size: size ?? bytes.length,
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('navis_update_test_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    adapter = _ArtifactAdapter(bytes);
    dio = Dio()..httpClientAdapter = adapter;
    service = UpdateService(dio: dio);
  });

  tearDown(() async {
    dio.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  test('SHA-256 mismatch throws and deletes downloaded file', () async {
    await expectLater(
      service.downloadArtifact(info(hash: '0' * 64)),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(
      File(p.join(temp.path, 'navis_updates', 'navis.zip')).existsSync(),
      isFalse,
    );
  });

  test('size mismatch throws and deletes downloaded file', () async {
    await expectLater(
      service.downloadArtifact(info(size: bytes.length + 1)),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(
      File(p.join(temp.path, 'navis_updates', 'navis.zip')).existsSync(),
      isFalse,
    );
  });

  for (final offHost in [
    'https://evil.com/navis.zip',
    'http://downloads.porthorion.com/navis/navis.zip',
    'https://downloads.porthorion.com.evil/navis/navis.zip',
  ]) {
    test('refuses $offHost before any request', () async {
      await expectLater(
        service.downloadArtifact(info(downloadUrl: offHost)),
        throwsA(isA<StateError>()),
      );
      expect(adapter.requests, isEmpty);
      expect(temp.listSync(), isEmpty);
    });
  }

  test(
    'matching size and SHA-256 returns verified file, including small files',
    () async {
      final progress = <double>[];
      final path = await service.downloadArtifact(
        info(),
        onProgress: progress.add,
      );
      expect(await File(path).readAsBytes(), bytes);
      expect(
        adapter.requests.single.extra,
        containsPair(navisUserInitiatedExtraKey, true),
      );
      expect(progress.last, 1);
    },
  );

  test('SHA-256 comparison is case insensitive', () async {
    final path = await service.downloadArtifact(
      info(hash: crypto.sha256.convert(bytes).toString().toUpperCase()),
    );
    expect(await File(path).readAsBytes(), bytes);
  });

  test('missing integrity metadata refuses download', () async {
    await expectLater(
      service.downloadArtifact(
        const UpdateInfo(
          tagName: 'v1.5.1',
          htmlUrl: AppConstants.updateManualDownloadUrl,
          delivery: UpdateDelivery.desktopSelfUpdate,
          downloadUrl: url,
          sha256: null,
          size: null,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requests, isEmpty);
  });
}
