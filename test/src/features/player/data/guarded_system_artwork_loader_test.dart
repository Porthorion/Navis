import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:file/file.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/integrations/data/artwork_call_recorder.dart';
import 'package:navis/src/features/player/data/guarded_system_artwork_loader.dart';

class _CacheManager extends Mock implements BaseCacheManager;

class _CacheFile extends Mock implements File {
  new(this.path);
  @override
  final String path;
}

void main() {
  final uri = Uri.parse('https://radio.test/art/now.jpg');
  final radio = MediaItem(id: 'radio:one', title: 'Station', artUri: uri);
  late _CacheManager cache;
  late IntegrationPolicy policy;
  late GuardedSystemArtworkLoader loader;
  late IntegrationCallRecorder recorder;

  setUp(() {
    cache = _CacheManager();
    policy = const IntegrationPolicy();
    recorder = IntegrationCallRecorder(logCalls: false);
    loader = GuardedSystemArtworkLoader(
      artworkRecorder: ArtworkCallRecorder(
        recorder: recorder,
        isServerUri: (uri) => uri.host == 'music.test',
      ),
      readCacheManager: () => cache,
      readPolicy: () => policy,
      readServerHost: () => 'music.test',
    );
  });

  test(
    'radio shares the widget cache key and dispatch-time feature gate',
    () async {
      final key = coverArtFeatureCacheKey('radio.nowPlaying', uri.toString());
      final headers = coverArtFeatureHeaders('radio.nowPlaying');
      when(
        () => cache.getSingleFile(uri.toString(), key: key, headers: headers),
      ).thenAnswer((_) async => _CacheFile(r'C:\cache\station.jpg'));
      expect(await loader.fetch(radio), r'C:\cache\station.jpg');
      verify(
        () => cache.getSingleFile(uri.toString(), key: key, headers: headers),
      ).called(1);
    },
  );

  for (final denied in [
    const IntegrationPolicy(masterEnabled: false),
    const IntegrationPolicy(disabledKeys: {'radio.nowPlaying'}),
    const IntegrationPolicy(disabledKeys: {'artwork'}),
  ]) {
    test('refused radio art never consults the cache ($denied)', () async {
      policy = denied;
      expect(loader.isAllowed(radio), isFalse);
      expect(await loader.fetch(radio), isNull);
      verifyZeroInteractions(cache);
      expect(
        recorder.recentCalls().single.outcome,
        IntegrationCallOutcome.blocked,
      );
      expect(
        recorder.countersFor(IntegrationService.serverLinkedArtwork).requests,
        0,
      );
    });
  }

  test('SMTC permission check records refusal without fetching', () {
    policy = const IntegrationPolicy(masterEnabled: false);
    expect(loader.checkAllowed(radio), isFalse);
    expect(
      recorder.recentCalls().single.outcome,
      IntegrationCallOutcome.blocked,
    );
    verifyZeroInteractions(cache);
  });

  test('policy revocation during a load refuses the completed file', () async {
    final pending = Completer<File>();
    when(
      () => cache.getSingleFile(
        uri.toString(),
        key: any(named: 'key'),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) => pending.future);
    final result = loader.fetch(radio);
    policy = const IntegrationPolicy(masterEnabled: false);
    pending.complete(_CacheFile(r'C:\cache\station.jpg'));
    expect(await result, isNull);
  });

  test('non-radio remote art uses the same untagged guarded cache', () async {
    when(
      () => cache.getSingleFile(
        uri.toString(),
        key: uri.toString(),
        headers: const <String, String>{},
      ),
    ).thenAnswer((_) async => _CacheFile(r'C:\cache\cover.jpg'));
    final item = radio.copyWith(id: 'song-1');
    expect(await loader.fetch(item), r'C:\cache\cover.jpg');
    verify(
      () => cache.getSingleFile(
        uri.toString(),
        key: uri.toString(),
        headers: const <String, String>{},
      ),
    ).called(1);
  });
}
