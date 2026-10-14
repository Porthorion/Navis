import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:audio_service_platform_interface/no_op_audio_service.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';

class _Cache extends Mock implements BaseCacheManager {}

class _PendingService extends NoOpAudioService {
  final configured = Completer<void>();
  int configureCalls = 0;
  @override
  Future<void> configure(ConfigureRequest request) {
    configureCalls++;
    return configured.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native configure wait is bounded and its process-wide future is retained',
    () async {
      final platform = _PendingService();
      AudioServicePlatform.instance = platform;
      var builders = 0;
      Future<void> attempt() async {
        await initNavisAudioServiceHandler(
          cacheManager: _Cache(),
          configureTimeout: const Duration(milliseconds: 10),
          builder: () {
            builders++;
            throw StateError('bound');
          },
        );
      }

      await expectLater(attempt(), throwsA(isA<TimeoutException>()));
      await expectLater(attempt(), throwsA(isA<TimeoutException>()));
      expect(platform.configureCalls, 1);
      expect(builders, 0);
      platform.configured.complete();
      await expectLater(attempt(), throwsA(isA<StateError>()));
      expect(platform.configureCalls, 1);
      expect(builders, 1);
    },
  );
}
