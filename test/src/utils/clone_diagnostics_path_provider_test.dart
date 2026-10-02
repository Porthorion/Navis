import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/utils/clone_diagnostics_path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Stands in for the platform implementation, whose directories belong to
/// the user's real profile.
class _RealProfilePathProvider extends PathProviderPlatform {
  new(this.home);

  final Directory home;

  String _path(String name) => p.join(home.path, name);

  @override
  Future<String?> getTemporaryPath() async => _path('tmp');

  @override
  Future<String?> getApplicationSupportPath() async => _path('support');

  @override
  Future<String?> getApplicationCachePath() async => _path('cache');

  @override
  Future<String?> getApplicationDocumentsPath() async => _path('Documents');

  @override
  Future<String?> getLibraryPath() async => _path('Library');

  @override
  Future<String?> getDownloadsPath() async => _path('Downloads');

  @override
  Future<String?> getExternalStoragePath() async => _path('external');

  @override
  Future<List<String>?> getExternalCachePaths() async => [
    _path('external-cache'),
  ];

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [_path('external-${type?.name}')];
}

void main() {
  late Directory sandbox;
  late Directory realHome;
  late Directory runRoot;
  late PathProviderPlatform original;

  setUp(() {
    original = PathProviderPlatform.instance;
    sandbox = Directory.systemTemp.createTempSync('clone_path_provider_');
    realHome = Directory(p.join(sandbox.path, 'real'))..createSync();
    runRoot = Directory(p.join(sandbox.path, 'run'));
    PathProviderPlatform.instance = CloneDiagnosticsPathProvider(
      root: runRoot.path,
      platform: _RealProfilePathProvider(realHome),
    );
  });

  tearDown(() {
    PathProviderPlatform.instance = original;
    sandbox.deleteSync(recursive: true);
  });

  test('resolves per-user directories inside the run root', () async {
    expect(
      (await getApplicationSupportDirectory()).path,
      p.join(runRoot.path, 'support'),
    );
    expect((await getTemporaryDirectory()).path, p.join(runRoot.path, 'cache'));
    expect(
      (await getApplicationCacheDirectory()).path,
      p.join(runRoot.path, 'cache'),
    );
    expect(
      (await getApplicationDocumentsDirectory()).path,
      p.join(runRoot.path, 'documents'),
    );
    expect((await getLibraryDirectory()).path, p.join(runRoot.path, 'library'));
    expect(
      (await getDownloadsDirectory())!.path,
      p.join(runRoot.path, 'downloads'),
    );
    for (final name in [
      'support',
      'cache',
      'documents',
      'library',
      'downloads',
    ]) {
      expect(
        Directory(p.join(runRoot.path, name)).existsSync(),
        isTrue,
        reason: name,
      );
    }
    expect(realHome.listSync(), isEmpty);
  });

  test('a relative root resolves to an absolute path', () async {
    PathProviderPlatform.instance = CloneDiagnosticsPathProvider(
      root: p.relative(runRoot.path),
      platform: _RealProfilePathProvider(realHome),
    );

    expect(
      (await getApplicationSupportDirectory()).path,
      p.join(runRoot.path, 'support'),
    );
  });

  test('external storage keeps the platform answer', () async {
    final clone = PathProviderPlatform.instance;

    expect(
      await clone.getExternalStoragePath(),
      p.join(realHome.path, 'external'),
    );
    expect(await clone.getExternalCachePaths(), [
      p.join(realHome.path, 'external-cache'),
    ]);
    expect(await clone.getExternalStoragePaths(type: StorageDirectory.music), [
      p.join(realHome.path, 'external-music'),
    ]);
  });

  test('app and plugin state is written inside the run root', () async {
    await UpdateCheckStore().recordCheck(DateTime.utc(2026, 10, 2));
    // flutter_cache_manager resolves its own index directory; the default
    // image cache used by several widgets is one of these.
    final repository = JsonCacheInfoRepository(
      databaseName: 'libCachedImageData',
    );
    await repository.open();
    await repository.insert(
      CacheObject(
        'https://example.test/cover.jpg',
        relativePath: 'cover.jpg',
        validTill: DateTime.utc(2026, 11, 2),
      ),
    );
    await repository.close();

    final support = p.join(runRoot.path, 'support');
    expect(
      File(p.join(support, 'update_check_state.json')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(support, 'libCachedImageData.json')).existsSync(),
      isTrue,
    );
    expect(realHome.listSync(), isEmpty);
  });
}
