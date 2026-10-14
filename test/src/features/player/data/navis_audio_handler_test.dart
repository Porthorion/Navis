import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/mediakit_player.dart' show MediaKitPlayer;
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

void main() {
  group('NavisAudioHandler fallback helpers', () {
    test('radio reconnects media-kit source failures but leaves Android renderer failures terminal', () {
      expect(
        navisShouldReconnectRadioSource(
          errorCode: MediaKitPlayer.kErrorCode,
          usesMediaKit: true,
        ),
        isTrue,
      );
      expect(
        navisShouldReconnectRadioSource(errorCode: 1, usesMediaKit: false),
        isFalse,
      );
      expect(
        navisShouldReconnectRadioSource(errorCode: 0, usesMediaKit: false),
        isTrue,
      );
      expect(
        navisShouldReconnectRadioSource(errorCode: 2001, usesMediaKit: false),
        isTrue,
      );
    });
    for (final (playing, transportAction) in [
      (false, MediaAction.play),
      (true, MediaAction.pause),
    ]) {
      test('notification controls are ordered (playing=$playing)', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 3,
          currentIndex: 1,
          isRadioMode: false,
          duration: const Duration(minutes: 3),
          processingState: AudioProcessingState.ready,
          playing: playing,
        );
        expect(
          navisNotificationControls(capabilities: capabilities)
              .map((control) => control.action),
          [MediaAction.skipToPrevious, transportAction, MediaAction.skipToNext],
        );
      });
    }

    group('OS media control capabilities', () {
      test('idle exposes no transport controls', () {
        final capabilities = navisOsControlCapabilitiesForSnapshot(
          const PlaybackSnapshot.idle(),
        );

        expect(capabilities.canPlay, isFalse);
        expect(capabilities.canPause, isFalse);
        expect(capabilities.canStop, isFalse);
        expect(capabilities.canSeek, isFalse);
        expect(capabilities.canSkipNext, isFalse);
        expect(capabilities.canSkipPrevious, isFalse);
        expect(capabilities.isLive, isFalse);
        expect(navisNotificationControls(capabilities: capabilities), isEmpty);
      });

      void capabilityCase(
        String name, {
        int queueLength = 1,
        int? currentIndex = 0,
        bool isRadio = false,
        Duration duration = const Duration(minutes: 4),
        AudioProcessingState state = AudioProcessingState.ready,
        bool playing = false,
        Set<String> yes = const <String>{},
        Set<String> no = const <String>{},
      }) {
        test(name, () {
          final capabilities = navisOsControlCapabilities(
            queueLength: queueLength,
            currentIndex: currentIndex,
            isRadioMode: isRadio,
            duration: duration,
            processingState: state,
            playing: playing,
          );
          final actual = <String, bool>{
            'play': capabilities.canPlay,
            'pause': capabilities.canPause,
            'stop': capabilities.canStop,
            'seek': capabilities.canSeek,
            'next': capabilities.canSkipNext,
            'previous': capabilities.canSkipPrevious,
            'live': capabilities.isLive,
          };
          for (final (flags, expected) in [(yes, true), (no, false)]) {
            for (final flag in flags) {
              expect(actual[flag], expected, reason: flag);
            }
          }
        });
      }

      capabilityCase(
        'loading queue disables play until ready',
        duration: const Duration(minutes: 3),
        state: AudioProcessingState.loading,
        yes: {'stop', 'seek'},
        no: {'play', 'pause'},
      );
      capabilityCase(
        'radio is live and not seekable or skippable',
        queueLength: 0,
        currentIndex: null,
        isRadio: true,
        duration: Duration.zero,
        playing: true,
        yes: {'live', 'pause', 'stop'},
        no: {'seek', 'next', 'previous'},
      );
      capabilityCase(
        'single-track queue exposes previous to restart current track',
        yes: {'play', 'stop', 'seek', 'previous'},
        no: {'pause', 'next'},
      );
      capabilityCase(
        'middle queue position exposes both skip directions',
        queueLength: 3,
        currentIndex: 1,
        playing: true,
        yes: {'previous', 'next'},
      );
      capabilityCase(
        'last queue position exposes only previous',
        queueLength: 3,
        currentIndex: 2,
        playing: true,
        yes: {'previous'},
        no: {'next'},
      );
      capabilityCase(
        'completed playback can be played again and seeked',
        queueLength: 2,
        currentIndex: 1,
        state: AudioProcessingState.completed,
        yes: {'play', 'seek', 'stop'},
        no: {'pause'},
      );
      capabilityCase(
        'unknown duration media is treated as non-seekable live media',
        duration: Duration.zero,
        playing: true,
        yes: {'live'},
        no: {'seek'},
      );

      test('paused restored queue advertises Auto playback entry points', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 1,
          currentIndex: 0,
          isRadioMode: false,
          duration: const Duration(minutes: 4),
          processingState: AudioProcessingState.ready,
          playing: false,
        );
        final actions = navisSystemActionsForCapabilities(capabilities);

        expect(capabilities.canPlay, isTrue);
        expect(actions, contains(MediaAction.play));
        expect(actions, contains(MediaAction.stop));
        expect(actions, contains(MediaAction.playFromMediaId));
        expect(actions, contains(MediaAction.playFromSearch));
        expect(actions, contains(MediaAction.prepare));
        expect(actions, contains(MediaAction.prepareFromMediaId));
        expect(actions, contains(MediaAction.prepareFromSearch));
      });

      test('completed queue insertion resumes from inserted item', () {
        expect(
          navisResumeIndexAfterQueueInsertion(
            wasPlayingBeforeMutation: true,
            queueWasCompletedBeforeMutation: true,
            processingStateAfterMutation: ProcessingState.ready,
            firstInsertedIndex: 1,
            queueLength: 2,
          ),
          1,
        );

        expect(
          navisResumeIndexAfterQueueInsertion(
            wasPlayingBeforeMutation: true,
            queueWasCompletedBeforeMutation: false,
            processingStateAfterMutation: ProcessingState.completed,
            firstInsertedIndex: 2,
            queueLength: 3,
          ),
          2,
        );
      });

      test('queue insertion does not resume when playback was paused', () {
        expect(
          navisResumeIndexAfterQueueInsertion(
            wasPlayingBeforeMutation: false,
            queueWasCompletedBeforeMutation: true,
            processingStateAfterMutation: ProcessingState.completed,
            firstInsertedIndex: 1,
            queueLength: 2,
          ),
          isNull,
        );
      });
    });

    group('Android Auto search request parsing', () {
      void searchCase(
        String name,
        String query,
        NavisAndroidAutoSearchType type, {
        Map<String, Object?>? extras,
        String? term,
      }) {
        test(name, () {
          final request = navisAndroidAutoSearchRequest(query, extras);
          expect(request.type, type);
          if (term != null) expect(request.term, term);
        });
      }

      searchCase(
        'empty query without extras requests instant radio',
        '',
        NavisAndroidAutoSearchType.empty,
        term: '',
      );
      searchCase(
        'artist focus uses the artist extra',
        '',
        NavisAndroidAutoSearchType.artist,
        extras: {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusArtist,
          AndroidAutoConstants.mediaArtistKey: 'Nina Simone',
        },
        term: 'Nina Simone',
      );
      searchCase(
        'album focus falls back to query when album extra is absent',
        'Blue',
        NavisAndroidAutoSearchType.album,
        extras: {
          AndroidAutoConstants.mediaFocusKey:
              AndroidAutoConstants.mediaFocusAlbum,
        },
        term: 'Blue',
      );
      searchCase(
        'playlist extra uses its scoped search',
        '',
        NavisAndroidAutoSearchType.playlist,
        extras: {AndroidAutoConstants.mediaPlaylistKey: 'Road'},
      );
      searchCase(
        'title extra uses its scoped search',
        '',
        NavisAndroidAutoSearchType.title,
        extras: {AndroidAutoConstants.mediaTitleKey: 'Feeling Good'},
      );
      // Genres are not a Navis concept: the platform genre focus and extra are
      // ignored and the spoken query is searched as typed.
      searchCase(
        'a genre voice intent is only a raw-query search',
        'jazz music',
        NavisAndroidAutoSearchType.general,
        extras: {
          AndroidAutoConstants.mediaFocusKey: 'vnd.android.cursor.item/genre',
          'android.intent.extra.genre': 'Jazz',
        },
        term: 'jazz music',
      );
      searchCase(
        'plain query uses general search',
        'Queen',
        NavisAndroidAutoSearchType.general,
        term: 'Queen',
      );
    });

    test('Android Auto playback failures expose a recoverable error state', () {
      final state = navisAndroidAutoPlaybackErrorState(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          controls: const <MediaControl>[MediaControl.pause],
        ),
        'Unable to play this item.',
      );

      expect(state.processingState, AudioProcessingState.error);
      expect(state.playing, isFalse);
      expect(state.errorCode, 1);
      expect(state.errorMessage, 'Unable to play this item.');
      expect(state.controls, isEmpty);
      expect(state.systemActions, contains(MediaAction.playFromMediaId));
      expect(state.systemActions, contains(MediaAction.playFromSearch));
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

    test('position-only playback changes are not structural changes', () {
      const base = PlaybackSnapshot(
        queueSongIds: <String>['song-1'],
        currentSongId: 'song-1',
        currentIndex: 0,
        playing: true,
        processingState: AudioProcessingState.ready,
        position: Duration(seconds: 10),
        duration: Duration(minutes: 3),
        bufferedPosition: Duration(seconds: 30),
        shuffleMode: AudioServiceShuffleMode.none,
        repeatMode: AudioServiceRepeatMode.none,
      );

      expect(
        navisPlaybackSnapshotsStructurallyEqual(
          base,
          base.copyWith(
            position: const Duration(seconds: 11),
            bufferedPosition: const Duration(seconds: 40),
          ),
        ),
        isTrue,
      );
      expect(
        navisPlaybackSnapshotsStructurallyEqual(
          base,
          base.copyWith(playing: false),
        ),
        isFalse,
      );
    });

    test('remote playback stall watcher only tracks remote loading states', () {
      expect(
        navisShouldWatchRemotePlaybackForStall(
          sourceKind: PlaybackSourceKind.lockCachedStream.name,
          processingState: AudioProcessingState.buffering,
        ),
        isTrue,
      );
      expect(
        navisShouldWatchRemotePlaybackForStall(
          sourceKind: PlaybackSourceKind.directStream.name,
          processingState: AudioProcessingState.loading,
        ),
        isTrue,
      );
      expect(
        navisShouldWatchRemotePlaybackForStall(
          sourceKind: PlaybackSourceKind.file.name,
          processingState: AudioProcessingState.buffering,
        ),
        isFalse,
      );
      expect(
        navisShouldWatchRemotePlaybackForStall(
          sourceKind: PlaybackSourceKind.directStream.name,
          processingState: AudioProcessingState.ready,
        ),
        isFalse,
      );
    });

    test('remote playback retries exactly once before skipping', () {
      expect(navisShouldRetryRemotePlayback(alreadyRetried: false), isTrue);
      expect(navisShouldRetryRemotePlayback(alreadyRetried: true), isFalse);
    });

    test('a finished queue shows as paused', () {
      // just_audio keeps `playing` true after the last song ends.
      expect(
        navisVisiblePlaying(playerPlaying: true, queueFinished: true),
        isFalse,
      );
      expect(
        navisVisiblePlaying(playerPlaying: true, queueFinished: false),
        isTrue,
      );
      expect(
        navisVisiblePlaying(playerPlaying: false, queueFinished: false),
        isFalse,
      );
    });

    test('only the transition into completed finishes the queue', () {
      expect(
        navisQueueJustFinished(
          previous: ProcessingState.ready,
          current: ProcessingState.completed,
          continuingPastCompletion: false,
          position: _end,
          duration: _end,
        ),
        isTrue,
      );
      // The Linux backend keeps reporting completed while a restart plays.
      expect(
        navisQueueJustFinished(
          previous: ProcessingState.completed,
          current: ProcessingState.completed,
          continuingPastCompletion: false,
          position: _end,
          duration: _end,
        ),
        isFalse,
      );
      expect(
        navisQueueJustFinished(
          previous: ProcessingState.ready,
          current: ProcessingState.completed,
          continuingPastCompletion: true,
          position: _end,
          duration: _end,
        ),
        isFalse,
      );
      expect(
        navisQueueJustFinished(
          previous: ProcessingState.buffering,
          current: ProcessingState.ready,
          continuingPastCompletion: false,
          position: _end,
          duration: _end,
        ),
        isFalse,
      );
      // Re-entering completed while a restarted song plays from the start.
      expect(
        navisQueueJustFinished(
          previous: ProcessingState.ready,
          current: ProcessingState.completed,
          continuingPastCompletion: false,
          position: const Duration(milliseconds: 300),
          duration: _end,
        ),
        isFalse,
      );
    });

    test('completed queue restart waits for pending queue fill', () {
      expect(
        navisShouldRestartCompletedQueue(
          queueLength: 1,
          currentIndex: 0,
          hasPendingLogicalQueue: true,
        ),
        isFalse,
      );
      expect(
        navisShouldRestartCompletedQueue(
          queueLength: 2,
          currentIndex: 0,
          hasPendingLogicalQueue: false,
        ),
        isFalse,
      );
      expect(
        navisShouldRestartCompletedQueue(
          queueLength: 2,
          currentIndex: 1,
          hasPendingLogicalQueue: false,
        ),
        isTrue,
      );
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
        navisCanSkipQueueItem(queueLength: 3, currentIndex: -1, forward: true),
        isFalse,
      );
      expect(
        navisCanSkipQueueItem(queueLength: 3, currentIndex: 3, forward: false),
        isFalse,
      );

      expect(
        navisCanSkipQueueItem(queueLength: 3, currentIndex: 0, forward: false),
        isFalse,
      );
      expect(
        navisCanSkipQueueItem(queueLength: 3, currentIndex: 2, forward: true),
        isFalse,
      );

      expect(
        navisCanSkipQueueItem(queueLength: 3, currentIndex: 0, forward: true),
        isTrue,
      );
      expect(
        navisCanSkipQueueItem(queueLength: 3, currentIndex: 2, forward: false),
        isTrue,
      );
    });

    group('queue replacement metadata resolver', () {
      final queue = <MediaItem>[
        const MediaItem(id: 'song-1', title: 'First Song'),
        const MediaItem(id: 'song-2', title: 'Second Song'),
        const MediaItem(id: 'song-3', title: 'Third Song'),
      ];

      test(
        'stale backend index resolves to anchored song and final queue index',
        () {
          final resolved = navisResolveQueueMetadata(
            queueItems: queue,
            backendCurrentIndex: 0,
            fallbackMediaItem: queue[1],
            anchor: NavisQueueReplacementMetadataAnchor(
              expectedIndex: 1,
              mediaItem: queue[1],
            ),
          );

          expect(resolved.mediaItem?.id, 'song-2');
          expect(resolved.currentIndex, 1);
        },
      );

      test('pending logical queue resolves anchored song before transport catches up', () {
        final resolved = navisResolveQueueMetadata(
          queueItems: <MediaItem>[queue[1]],
          logicalQueueSongIds: const <String>['song-1', 'song-2', 'song-3'],
          backendCurrentIndex: 0,
          fallbackMediaItem: queue[1],
          anchor: NavisQueueReplacementMetadataAnchor(
            expectedIndex: 1,
            mediaItem: queue[1],
          ),
        );

        expect(resolved.mediaItem?.id, 'song-2');
        expect(resolved.currentIndex, 1);
      });

      test(
        'matching backend index confirms anchor and uses normal metadata',
        () {
          final anchor = NavisQueueReplacementMetadataAnchor(
            expectedIndex: 1,
            mediaItem: queue[1],
          );

          expect(
            navisIsQueueReplacementMetadataAnchorConfirmed(
              queueItems: queue,
              backendCurrentIndex: 1,
              anchor: anchor,
            ),
            isTrue,
          );

          final resolved = navisResolveQueueMetadata(
            queueItems: queue,
            backendCurrentIndex: 1,
            fallbackMediaItem: queue.first,
            anchor: anchor,
          );

          expect(resolved.mediaItem?.id, 'song-2');
          expect(resolved.currentIndex, 1);
        },
      );

      test(
        'fallback media item recovers queue index when backend is unset',
        () {
          final resolved = navisResolveQueueMetadata(
            queueItems: queue,
            backendCurrentIndex: null,
            fallbackMediaItem: queue[1],
            anchor: null,
          );

          expect(resolved.mediaItem?.id, 'song-2');
          expect(resolved.currentIndex, 1);
        },
      );

      test('no anchor preserves backend index behavior', () {
        final resolved = navisResolveQueueMetadata(
          queueItems: queue,
          backendCurrentIndex: 0,
          fallbackMediaItem: queue[1],
          anchor: null,
        );

        expect(resolved.mediaItem?.id, 'song-1');
        expect(resolved.currentIndex, 0);
      });

      test('invalid anchor falls back safely', () {
        final resolved = navisResolveQueueMetadata(
          queueItems: queue,
          backendCurrentIndex: 0,
          fallbackMediaItem: queue[1],
          anchor: const NavisQueueReplacementMetadataAnchor(
            expectedIndex: 8,
            mediaItem: MediaItem(id: 'missing-song', title: 'Missing Song'),
          ),
        );

        expect(resolved.mediaItem?.id, 'song-1');
        expect(resolved.currentIndex, 0);
      });
    });

    group('previous track action helper', () {
      void previousCase(
        String name,
        int queueLength,
        int? currentIndex,
        Duration position,
        NavisPreviousTrackAction expected,
      ) {
        test(name, () {
          expect(
            navisResolvePreviousTrackAction(
              queueLength: queueLength,
              currentIndex: currentIndex,
              position: position,
            ),
            expected,
          );
        });
      }

      const none = NavisPreviousTrackAction.none;
      const restart = NavisPreviousTrackAction.restartCurrent;
      const back = NavisPreviousTrackAction.skipToPrevious;
      previousCase(
        'no current index returns none',
        1,
        null,
        Duration.zero,
        none,
      );
      previousCase(
        'single track restarts current',
        1,
        0,
        Duration.zero,
        restart,
      );
      previousCase(
        'first track of a longer queue restarts current',
        3,
        0,
        const Duration(seconds: 1),
        restart,
      );
      previousCase(
        'previous exists and position above threshold restarts current',
        3,
        1,
        const Duration(seconds: 3, milliseconds: 1),
        restart,
      );
      previousCase(
        'previous exists and position at or below threshold skips back',
        3,
        1,
        const Duration(seconds: 3),
        back,
      );
      previousCase(
        'no previous item restarts at or below threshold',
        2,
        0,
        navisPreviousTrackRestartThreshold,
        restart,
      );
    });

    test('resolved playback extras preserve transcode metadata', () {
      final song = SongsTableData(
        isProvisional: false,
        isExternal: false,
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

    test('resolved playback extras never carry the stream URL', () {
      final song = SongsTableData(
        isProvisional: false,
        isExternal: false,
        id: 'song-1',
        title: 'Song 1',
      );
      final source = ResolvedPlaybackSource.directStream(
        songId: song.id,
        uri: Uri.parse(
          'https://example.com/rest/stream.view?u=alice&t=secret-token'
          '&s=secret-salt&id=song-1',
        ),
        metadata: const ResolvedPlaybackMetadata(isTranscoded: false),
      );

      final extras = navisResolvedPlaybackExtras(song: song, source: source);

      // audio_service publishes every String extra to the media session.
      for (final value in extras.values.whereType<String>()) {
        expect(value, isNot(contains('secret')));
      }
      expect(extras.containsKey('streamUri'), isFalse);
    });

    test(
      'whole-entity queues retain supplied remote rows after identity match',
      () {
        final local = SongsTableData(
          isProvisional: false,
          isExternal: false,
          id: 'local-song',
          title: 'Local song',
        );
        final remote = SongsTableData(
          isProvisional: true,
          isExternal: true,
          id: 'remote-song',
          title: 'Matched remote song',
        );

        final ids = navisQueueSourceIds(<SongsTableData>[
          local,
          remote,
        ], canonicalize: (id) => id == 'remote-song' ? 'local-song' : id);

        expect(ids, <String>['local-song', 'remote-song']);
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

    test('queue preload decision respects autoplay, gapless, and forced restore preloading', () {
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

      expect(
        navisShouldPreloadQueue(
          autoPlay: false,
          preloadWhenPaused: false,
          gaplessEnabled: false,
          forcePreloadWhenPaused: true,
        ),
        isTrue,
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
        message: 'Cannot initialize effect engine for type: 0bed4300-ddd6-11db-8f34-0002a5d5c51b Error: -3',
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

    test('native source ids include untagged lock-cached streams', () {
      final tagged = AudioSource.uri(
        Uri.parse('file:///music/a.flac'),
        tag: const MediaItem(id: 'song-a', title: 'A'),
      );
      // ignore: experimental_member_use, reason: Android rolling-cache playback uses LockCachingAudioSource.
      final lockCached = LockCachingAudioSource(
        Uri.parse(
          'https://music.test/rest/stream.view?id=song-b&u=me&t=tok&s=salt',
        ),
        cacheFile: File(
          '${Directory.systemTemp.path}/navis-native-source-id-test.flac',
        ),
      );
      final untagged = AudioSource.uri(Uri.parse('https://radio.test/live'));

      expect(navisNativeSourceSongId(tagged), 'song-a');
      expect(navisNativeSourceSongId(lockCached), 'song-b');
      expect(navisNativeSourceSongId(untagged), isNull);
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

const _end = Duration(seconds: 4);
