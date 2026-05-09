import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
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

    test('instant mix control is removed; controls always have 3 items', () {
      final pausedControls = navisNotificationControls(isPlaying: false);
      final playingControls = navisNotificationControls(isPlaying: true);

      expect(pausedControls.length, 3);
      expect(playingControls.length, 3);
    });

    test('notification compact indices align to transport controls', () {
      expect(navisNotificationCompactActionIndices, const <int>[0, 1, 2]);
    });

    test('linux MPRIS helper registers only on Linux runtime', () {
      var registerCalls = 0;
      final infos = <String>[];
      final warnings = <String>[];

      final registered = navisRegisterLinuxMprisIfSupported(
        isLinuxRuntime: true,
        registerMpris: () {
          registerCalls += 1;
        },
        logInfo: infos.add,
        logWarning: warnings.add,
      );

      expect(registered, isTrue);
      expect(registerCalls, 1);
      expect(infos, hasLength(1));
      expect(warnings, isEmpty);

      final skipped = navisRegisterLinuxMprisIfSupported(
        isLinuxRuntime: false,
        registerMpris: () {
          registerCalls += 1;
        },
        logInfo: infos.add,
        logWarning: warnings.add,
      );

      expect(skipped, isFalse);
      expect(registerCalls, 1);
    });

    test('linux MPRIS helper logs warning and continues on failure', () {
      final infos = <String>[];
      final warnings = <String>[];

      final registered = navisRegisterLinuxMprisIfSupported(
        isLinuxRuntime: true,
        registerMpris: () {
          throw StateError('dbus unavailable');
        },
        logInfo: infos.add,
        logWarning: warnings.add,
      );

      expect(registered, isFalse);
      expect(infos, isEmpty);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('Linux MPRIS registration failed.'));
      expect(warnings.single, contains('dbus unavailable'));
    });

    group('Android Auto search request parsing', () {
      test('empty query without extras requests instant radio', () {
        final request = navisAndroidAutoSearchRequest('');
        expect(request.type, NavisAndroidAutoSearchType.empty);
        expect(request.term, isEmpty);
      });

      test('artist focus uses the artist extra', () {
        final request = navisAndroidAutoSearchRequest('', {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusArtist,
          AndroidAutoConstants.mediaArtistKey: 'Nina Simone',
        });
        expect(request.type, NavisAndroidAutoSearchType.artist);
        expect(request.term, 'Nina Simone');
      });

      test('album focus falls back to query when album extra is absent', () {
        final request = navisAndroidAutoSearchRequest('Blue', {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusAlbum,
        });
        expect(request.type, NavisAndroidAutoSearchType.album);
        expect(request.term, 'Blue');
      });

      test('playlist, genre, and title extras are classified', () {
        expect(
          navisAndroidAutoSearchRequest('', {
            AndroidAutoConstants.mediaPlaylistKey: 'Road',
          }).type,
          NavisAndroidAutoSearchType.playlist,
        );
        expect(
          navisAndroidAutoSearchRequest('', {
            AndroidAutoConstants.mediaGenreKey: 'Jazz',
          }).type,
          NavisAndroidAutoSearchType.genre,
        );
        expect(
          navisAndroidAutoSearchRequest('', {
            AndroidAutoConstants.mediaTitleKey: 'Feeling Good',
          }).type,
          NavisAndroidAutoSearchType.title,
        );
      });

      test('plain query uses general search', () {
        final request = navisAndroidAutoSearchRequest('Queen');
        expect(request.type, NavisAndroidAutoSearchType.general);
        expect(request.term, 'Queen');
      });
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

    test('playback speed normalize helper clamps to supported range', () {
      expect(navisNormalizePlaybackSpeed(0.25), 0.5);
      expect(navisNormalizePlaybackSpeed(1.25), 1.25);
      expect(navisNormalizePlaybackSpeed(2.5), 2.0);
    });

    test(
      'seek recovery helper detects lock-cached seek failures',
      () {
        // Snap-to-zero: seek to 48s, land at 250ms.
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'lockCachedStream',
            requestedPosition: const Duration(seconds: 48),
            actualPosition: const Duration(milliseconds: 250),
          ),
          isTrue,
        );

        // Snap-to-buffer-boundary: seek to 60s, land at 8s (buffer boundary).
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'lockCachedStream',
            requestedPosition: const Duration(seconds: 60),
            actualPosition: const Duration(seconds: 8),
          ),
          isTrue,
        );

        // Non-lockCachedStream source: never recover.
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'directStream',
            requestedPosition: const Duration(seconds: 48),
            actualPosition: const Duration(milliseconds: 250),
          ),
          isFalse,
        );

        // Small seek target (≤ 2s): never recover.
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'lockCachedStream',
            requestedPosition: const Duration(seconds: 1),
            actualPosition: const Duration(milliseconds: 250),
          ),
          isFalse,
        );

        // Successful seek that landed within 2s of target: no recovery.
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'lockCachedStream',
            requestedPosition: const Duration(seconds: 30),
            actualPosition: const Duration(milliseconds: 29500),
          ),
          isFalse,
        );

        // Overshoot: actual > requested — no recovery (shouldn't happen, but
        // guard against false positives).
        expect(
          navisShouldRecoverSeekToDirectStream(
            sourceKind: 'lockCachedStream',
            requestedPosition: const Duration(seconds: 30),
            actualPosition: const Duration(seconds: 32),
          ),
          isFalse,
        );
      },
    );

    test('crossfade handoff seek helper seeks on index mismatch', () {
      expect(
        navisShouldSeekCrossfadeHandoff(
          handoffTargetIndex: 6,
          currentIndex: 5,
          jumpDelta: const Duration(milliseconds: 50),
          seekCorrectionThreshold: const Duration(milliseconds: 750),
        ),
        isTrue,
      );
    });

    test('crossfade handoff seek helper seeks on large position delta', () {
      expect(
        navisShouldSeekCrossfadeHandoff(
          handoffTargetIndex: 6,
          currentIndex: 6,
          jumpDelta: const Duration(seconds: 2),
          seekCorrectionThreshold: const Duration(milliseconds: 750),
        ),
        isTrue,
      );
    });

    test(
      'crossfade handoff seek helper skips seek when index and delta are stable',
      () {
        expect(
          navisShouldSeekCrossfadeHandoff(
            handoffTargetIndex: 6,
            currentIndex: 6,
            jumpDelta: const Duration(milliseconds: 200),
            seekCorrectionThreshold: const Duration(milliseconds: 750),
          ),
          isFalse,
        );
      },
    );

    test(
      'android crossfade fallback helper avoids regular CD-quality FLAC',
      () {
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: true,
            format: 'flac',
            sampleRate: 44100,
          ),
          isFalse,
        );
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: true,
            format: 'audio/flac',
            sampleRate: 44100,
          ),
          isFalse,
        );
      },
    );

    test(
      'android crossfade fallback helper enables for high sample-rate audio',
      () {
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: true,
            format: 'mp3',
            sampleRate: 96000,
          ),
          isTrue,
        );
      },
    );

    test(
      'android crossfade fallback helper enables for high-rate lossless audio',
      () {
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: true,
            format: 'flac',
            sampleRate: 96000,
          ),
          isTrue,
        );
      },
    );

    test(
      'android crossfade fallback helper stays off for regular lossy audio',
      () {
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: true,
            format: 'mp3',
            sampleRate: 44100,
          ),
          isFalse,
        );
        expect(
          navisShouldUseAndroidSequentialCrossfadeFallback(
            isAndroidRuntime: false,
            format: 'flac',
            sampleRate: 96000,
          ),
          isFalse,
        );
      },
    );

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

    test('resolved playback extras preserve transcode metadata', () {
      final song = SongsTableData(
        id: 'song-1',
        title: 'Song 1',
        albumId: 'album-1',
        artistId: 'artist-1',
        bitRate: 900,
        suffix: 'flac',
      );
      final source = ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: Uri.parse(
          'https://example.com/rest/stream.view?id=song-1&maxBitRate=192',
        ),
        metadata: const ResolvedPlaybackMetadata(
          bitRate: 192,
          isTranscoded: true,
        ),
      );

      final extras = navisResolvedPlaybackExtras(song: song, source: source);

      expect(extras['resolvedFormat'], isNull);
      expect(extras['resolvedBitRate'], 192);
      expect(extras['transcodingApplied'], isTrue);
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

    test('effective gapless is enabled when crossfade is enabled', () {
      expect(
        navisEffectiveGaplessEnabled(
          gaplessEnabled: false,
          crossfadeEnabled: true,
        ),
        isTrue,
      );
      expect(
        navisEffectiveGaplessEnabled(
          gaplessEnabled: true,
          crossfadeEnabled: false,
        ),
        isTrue,
      );
      expect(
        navisEffectiveGaplessEnabled(
          gaplessEnabled: false,
          crossfadeEnabled: false,
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

    test('lock-cached preference is disabled for bypassed songs', () {
      expect(
        navisShouldUseLockCachingForSong(
          preferLockCaching: true,
          isBypassedForSong: false,
        ),
        isTrue,
      );
      expect(
        navisShouldUseLockCachingForSong(
          preferLockCaching: true,
          isBypassedForSong: true,
        ),
        isFalse,
      );
      expect(
        navisShouldUseLockCachingForSong(
          preferLockCaching: false,
          isBypassedForSong: false,
        ),
        isFalse,
      );
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
