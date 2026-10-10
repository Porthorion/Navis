import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/utils/android_diagnostics_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _AndroidPathProvider extends PathProviderPlatform {
  new(this.externalFiles);

  final String? externalFiles;

  @override
  Future<String?> getExternalStoragePath() async => externalFiles;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.navis.app/diagnostics_handshake');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory externalFiles;
  late PathProviderPlatform original;
  late List<String> handshakeCalls;

  setUp(() {
    externalFiles = Directory.systemTemp.createTempSync('android_diagnostics_');
    original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _AndroidPathProvider(externalFiles.path);
    handshakeCalls = [];
    // An activity may never attach to the service-owned engine. Startup must
    // use the registered package/path providers even if this channel is absent.
    messenger.setMockMethodCallHandler(channel, (call) async {
      handshakeCalls.add(call.method);
      throw MissingPluginException();
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    PathProviderPlatform.instance = original;
    externalFiles.deleteSync(recursive: true);
  });

  for (final package in [
    ('com.navis.app.navis', false),
    ('com.navis.app.navis.dev', true),
    ('com.example.player', true),
  ]) {
    test(
      'resolves sidecar identity for ${package.$1} without an activity',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'Navis',
          packageName: package.$1,
          version: '1.5.0',
          buildNumber: '10500',
          buildSignature: '',
        );

        expect(await androidDiagnosticsIsSidecar(), package.$2);
        expect(handshakeCalls, isEmpty);
      },
    );
  }

  test(
    'creates artifacts below external app files without an activity',
    () async {
      final root = await androidDiagnosticsArtifactRoot();

      expect(root.path, p.join(externalFiles.path, 'navis-diagnostics'));
      expect(root.existsSync(), isTrue);
      expect((await androidDiagnosticsArtifactRoot()).path, root.path);
      expect(handshakeCalls, isEmpty);
    },
  );

  test(
    'fails when external app files are unavailable without a channel call',
    () async {
      PathProviderPlatform.instance = _AndroidPathProvider(null);

      await expectLater(androidDiagnosticsArtifactRoot(), throwsStateError);
      expect(handshakeCalls, isEmpty);
    },
  );

  test(
    'propagates artifact directory creation failure without a channel call',
    () async {
      File(p.join(externalFiles.path, 'navis-diagnostics'))
          .writeAsStringSync('occupied');

      await expectLater(
        androidDiagnosticsArtifactRoot(),
        throwsA(isA<FileSystemException>()),
      );
      expect(handshakeCalls, isEmpty);
    },
  );
}
