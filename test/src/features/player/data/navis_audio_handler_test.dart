import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';

void main() {
  group('NavisAudioHandler fallback helpers', () {
    test('queue preload decision respects autoplay and gapless settings', () {
      expect(
        navisShouldPreloadQueue(
          autoPlay: true,
          preloadWhenPaused: false,
          gaplessEnabled: false,
        ),
        isTrue,
      );

      expect(
        navisShouldPreloadQueue(
          autoPlay: false,
          preloadWhenPaused: true,
          gaplessEnabled: true,
        ),
        isTrue,
      );

      expect(
        navisShouldPreloadQueue(
          autoPlay: false,
          preloadWhenPaused: true,
          gaplessEnabled: false,
        ),
        isFalse,
      );
    });

    test('detects Android DSP initialization failure signatures', () {
      final dspError = PlatformException(
        code: 'error',
        message:
            'Cannot initialize effect engine for type: 0bed4300-ddd6-11db-8f34-0002a5d5c51b Error: -3',
      );

      expect(
        navisIsAndroidDspInitializationFailure(
          dspError,
          isAndroidRuntime: true,
        ),
        isTrue,
      );

      expect(
        navisIsAndroidDspInitializationFailure(
          dspError,
          isAndroidRuntime: false,
        ),
        isFalse,
      );
    });

    test('retries queue apply when lock-cached source setup fails', () {
      final shouldRetry = navisShouldRetryQueueApplyWithDirectSources(
        sourceKinds: const <PlaybackSourceKind>[
          PlaybackSourceKind.lockCachedStream,
        ],
        error: StateError('lock-cache setup failed'),
        isAndroidRuntime: true,
      );

      expect(shouldRetry, isTrue);
    });

    test('retries queue apply when DSP init fails on direct sources', () {
      final dspError = PlatformException(
        code: 'error',
        message: 'AudioEffect Equalizer cannot initialize effect engine',
      );

      final shouldRetry = navisShouldRetryQueueApplyWithDirectSources(
        sourceKinds: const <PlaybackSourceKind>[
          PlaybackSourceKind.directStream,
        ],
        error: dspError,
        isAndroidRuntime: true,
      );

      expect(shouldRetry, isTrue);
    });

    test('does not retry when non-DSP error occurs on direct/file sources', () {
      final directShouldRetry = navisShouldRetryQueueApplyWithDirectSources(
        sourceKinds: const <PlaybackSourceKind>[
          PlaybackSourceKind.directStream,
        ],
        error: StateError('network timeout'),
        isAndroidRuntime: true,
      );
      final fileShouldRetry = navisShouldRetryQueueApplyWithDirectSources(
        sourceKinds: const <PlaybackSourceKind>[PlaybackSourceKind.file],
        error: StateError('file unreadable'),
        isAndroidRuntime: true,
      );

      expect(directShouldRetry, isFalse);
      expect(fileShouldRetry, isFalse);
    });
  });
}
