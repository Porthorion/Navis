import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/network_usage_meter.dart';

class _NetworkUsageMeter extends Fake implements NetworkUsageMeter;

void main() {
  test(
    'playback artwork refuses safely after its provider is disposed',
    () async {
      final provider = Provider<CoverArtHttpFileService>(
        createPlaybackArtworkFileService,
      );
      final container = ProviderContainer(
        overrides: [
          networkUsageMeterProvider.overrideWithValue(_NetworkUsageMeter()),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(),
          ),
          serverHostProvider.overrideWithValue('music.example.com'),
          integrationCallRecorderProvider.overrideWithValue(
            IntegrationCallRecorder(logCalls: false),
          ),
        ],
      );
      final service = container.read(provider);
      addTearDown(service.close);
      container.dispose();

      await expectLater(
        service.get('https://music.example.com/cover.jpg'),
        throwsA(isA<CoverArtBlockedException>()),
      );
    },
  );
}
