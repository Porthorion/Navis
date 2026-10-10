import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/clone_diagnostics_path_provider.dart';
import 'package:navis/src/utils/network_usage_meter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../../helpers/test_database.dart';

class _NetworkUsageMeter extends Fake implements NetworkUsageMeter;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clone cover cache uses the folder measured by storage accounting', () async {
    final root = Directory.systemTemp.createTempSync('clone_cover_cache_');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = CloneDiagnosticsPathProvider(
      root: root.path,
      platform: original,
    );
    final database = createTestDatabase();
    final container = ProviderContainer(
      overrides: withTestDatabase(
        database,
        overrides: [
          networkUsageMeterProvider.overrideWithValue(_NetworkUsageMeter()),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(),
          ),
          integrationCallRecorderProvider.overrideWithValue(
            IntegrationCallRecorder(logCalls: false),
          ),
        ],
      ),
    );
    final manager = container.read(coverArtCacheManagerProvider);
    addTearDown(() async {
      container.dispose();
      // Provider disposal starts this asynchronously; await it before deleting.
      await manager.dispose();
      await database.close();
      PathProviderPlatform.instance = original;
      root.deleteSync(recursive: true);
    });

    final file = await manager.config.fileSystem.createFile('cover.jpg');
    await file.writeAsBytes([1, 2, 3]);

    expect(manager.config.cacheKey, coverArtCacheKey);
    expect(
      file.path,
      p.join(root.path, 'cache', coverArtCacheKey, 'cover.jpg'),
    );
    expect(await coverArtCacheStorageBytes(), 3);
  }, skip: !sqliteAvailable);
}
