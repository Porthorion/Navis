import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';

void main() {
  group('NavisAudioHandler fallback helpers', () {
    test('notification controls are stable and ordered', () {
      final pausedControls = navisNotificationControls(isPlaying: false);
      final playingControls = navisNotificationControls(isPlaying: true);

      expect(pausedControls.length, 3);
      expect(playingControls.length, 3);

      expect(pausedControls[0].action, MediaAction.skipToPrevious);
      expect(pausedControls[1].action, MediaAction.play);
      expect(pausedControls[2].action, MediaAction.skipToNext);

      expect(playingControls[0].action, MediaAction.skipToPrevious);
      expect(playingControls[1].action, MediaAction.pause);
      expect(playingControls[2].action, MediaAction.skipToNext);
    });

    test('notification compact indices align to transport controls', () {
      expect(navisNotificationCompactActionIndices, const <int>[0, 1, 2]);
    });

    test('seek sanitize helper clamps negatives to zero', () {
      expect(
        navisSanitizeSeekPosition(const Duration(seconds: -5)),
        Duration.zero,
      );
      expect(
        navisSanitizeSeekPosition(const Duration(milliseconds: 1)),
        const Duration(milliseconds: 1),
      );
      expect(navisSanitizeSeekPosition(Duration.zero), Duration.zero);
    });

    test('skip helper enforces queue bounds for next and previous', () {
      expect(
        navisCanSkipQueueItem(
          queueLength: 0,
          currentIndex: null,
          forward: true,
        ),
        isFalse,
      );
      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: -1,
          forward: true,
        ),
        isFalse,
      );
      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: 3,
          forward: false,
        ),
        isFalse,
      );

      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: 0,
          forward: false,
        ),
        isFalse,
      );
      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: 2,
          forward: true,
        ),
        isFalse,
      );

      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: 0,
          forward: true,
        ),
        isTrue,
      );
      expect(
        navisCanSkipQueueItem(
          queueLength: 3,
          currentIndex: 2,
          forward: false,
        ),
        isTrue,
      );
    });

    test(
      'transport helper runs command before persistence and does not skip persist',
      () async {
        final calls = <String>[];

        Future<void> persistSafely(
          Future<void> Function() persistOperation, {
          required String context,
        }) async {
          calls.add('persist-safely:$context:start');
          await persistOperation();
          calls.add('persist-safely:$context:end');
        }

        await navisRunTransportWithPersistence(
          transportOperation: () async {
            calls.add('transport');
          },
          persistOperation: () async {
            calls.add('persist');
          },
          persistSafely: persistSafely,
          persistenceContext: 'pause',
        );

        expect(
          calls,
          equals(<String>[
            'transport',
            'persist-safely:pause:start',
            'persist',
            'persist-safely:pause:end',
          ]),
        );
      },
    );

    test('persist helper swallows failures and logs warning', () async {
      final logs = <String>[];

      await navisPersistSafely(
        () async {
          throw StateError('write failed');
        },
        context: 'seek',
        logWarning: logs.add,
      );

      expect(logs, hasLength(1));
      expect(
        logs.single,
        contains('Playback state persistence failed during seek.'),
      );
      expect(logs.single, contains('write failed'));
    });

    test(
      'transport helper remains successful when persistence fails safely',
      () async {
        var transportRuns = 0;
        final logs = <String>[];

        await navisRunTransportWithPersistence(
          transportOperation: () async {
            transportRuns += 1;
          },
          persistOperation: () async {
            throw StateError('db unavailable');
          },
          persistSafely:
              (
                persistOperation, {
                required context,
              }) => navisPersistSafely(
                persistOperation,
                context: context,
                logWarning: logs.add,
              ),
          persistenceContext: 'play',
        );

        expect(transportRuns, 1);
        expect(logs, hasLength(1));
        expect(logs.single, contains('db unavailable'));
      },
    );

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
