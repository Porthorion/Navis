import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/integrations/data/integration_guard_interceptor.dart';
import 'package:navis/src/features/settings/data/update_install_mode.dart';
import 'package:navis/src/features/settings/data/update_service.dart';
import 'package:navis/src/features/settings/domain/update_delivery.dart';
import 'package:navis/src/features/settings/domain/update_info.dart';
import 'package:navis/src/utils/constants.dart';
import 'package:navis/src/features/integrations/domain/update_source.dart';
import 'package:path/path.dart' as p;

class _ArtifactAdapter implements HttpClientAdapter {
  new(this.bytes);
  final List<int> bytes;
  final List<RequestOptions> requests = [];
  String? redirect;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requests.length == 1 && redirect != null) {
      return ResponseBody.fromBytes(
        [],
        302,
        headers: {
          'location': [redirect!],
        },
      );
    }
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

  for (final host in [
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
  ]) {
    test('GitHub redirect to $host still rejects SHA-256 mismatch', () async {
      adapter.redirect = 'https://$host/artifact?token=fixture';
      service = UpdateService(dio: dio, source: UpdateSource.github);
      await expectLater(
        service.downloadArtifact(
          info(
            downloadUrl: 'https://github.com/Porthorion/Navis/releases/download/v1.5.1/navis.zip',
            hash: '0' * 64,
          ),
        ),
        throwsA(isA<UpdateIntegrityException>()),
      );
      expect(adapter.requests.map((r) => r.uri.host), ['github.com', host]);
      expect(adapter.requests.every((r) => !r.followRedirects), isTrue);
      expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
    });
  }

  test('redirect to an untrusted host is rejected before contact', () async {
    adapter.redirect = 'https://evil.com/artifact';
    await expectLater(
      service.downloadArtifact(info()),
      throwsA(isA<DioException>()),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('GitHub prefix is rejected by the Porthorion source', () async {
    await expectLater(
      service.downloadArtifact(
        info(
          downloadUrl: 'https://github.com/Porthorion/Navis/releases/download/v1.5.1/navis.zip',
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('desktop downloads use distinct private dirs instead of shared navis_updates', () async {
    final shared = await Directory(p.join(temp.path, 'navis_updates')).create();
    final chmod = await Process.run('chmod', ['777', shared.path]);
    expect(chmod.exitCode, 0);
    expect(shared.statSync().mode & 0x1ff, 0x1ff);

    final first = await service.downloadArtifact(info());
    final second = await service.downloadArtifact(info());
    final firstDir = Directory(p.dirname(first));
    final secondDir = Directory(p.dirname(second));
    expect(firstDir.path, isNot(secondDir.path));
    for (final dir in [firstDir, secondDir]) {
      expect(p.dirname(dir.path), temp.path);
      expect(p.basename(dir.path), startsWith('navis_update_'));
      expect(dir.statSync().mode & 0x1ff, 0x1c0);
    }
    expect(shared.listSync(), isEmpty);
    expect(await File(first).readAsBytes(), bytes);
    expect(await File(second).readAsBytes(), bytes);
  }, skip: Platform.isWindows);

  test(
    'Linux extraction stages inside the downloaded artifact private dir',
    () async {
      // This deliberately invalid archive fails before any updater launches.
      final downloadedPath = await service.downloadArtifact(info());
      await expectLater(
        service.applyDesktopUpdate(
          downloadedPath,
          UpdateInstallMode.linuxPortable,
        ),
        throwsA(isA<ProcessException>()),
      );
      final workDir = p.dirname(downloadedPath);
      expect(Directory(p.join(workDir, 'staging')).existsSync(), isTrue);
      expect(temp.listSync(), hasLength(1));
    },
    skip: !Platform.isLinux,
  );

  test(
    'cleanup removes stale update work dirs and preserves unrelated dirs',
    () async {
      final stale = await Directory(p.join(temp.path, 'navis_update_stale'))
          .create();
      await File(p.join(stale.path, 'artifact.zip')).writeAsString('stale');
      final legacy = await Directory(
        p.join(temp.path, 'navis_update_staging_123'),
      ).create();
      final unrelated = await Directory(p.join(temp.path, 'unrelated'))
          .create();
      await UpdateService.cleanupStaledUpdates();
      expect(stale.existsSync(), isFalse);
      expect(legacy.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
    },
  );

  test('cleanup does not follow top-level or nested symlinks', () async {
    final outside = await Directory.systemTemp.createTemp(
      'navis_cleanup_target_',
    );
    addTearDown(() => outside.delete(recursive: true));
    final marker = await File(p.join(outside.path, 'keep'))
        .writeAsString('keep');
    final topLink = await Link(p.join(temp.path, 'navis_update_link'))
        .create(outside.path);
    final stale = await Directory(p.join(temp.path, 'navis_update_stale'))
        .create();
    await Link(p.join(stale.path, 'nested')).create(outside.path);

    await UpdateService.cleanupStaledUpdates();

    expect(topLink.existsSync(), isTrue);
    expect(stale.existsSync(), isFalse);
    expect(await marker.readAsString(), 'keep');
  }, skip: Platform.isWindows);

  test('SHA-256 mismatch throws and deletes downloaded file', () async {
    await expectLater(
      service.downloadArtifact(info(hash: '0' * 64)),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('size mismatch throws and deletes downloaded file', () async {
    await expectLater(
      service.downloadArtifact(info(size: bytes.length + 1)),
      throwsA(isA<UpdateIntegrityException>()),
    );
    expect(adapter.requests, hasLength(1));
    expect(temp.listSync(recursive: true).whereType<File>(), isEmpty);
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
