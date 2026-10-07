import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auto/domain/android_auto_constants.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/data/playback_source_resolver.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';

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
        expect(
          navisNotificationControls(
            isPlaying: false,
            capabilities: capabilities,
          ),
          isEmpty,
        );
      });

      test('loading queue disables play until ready', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 1,
          currentIndex: 0,
          isRadioMode: false,
          duration: const Duration(minutes: 3),
          processingState: AudioProcessingState.loading,
          playing: false,
        );

        expect(capabilities.canPlay, isFalse);
        expect(capabilities.canPause, isFalse);
        expect(capabilities.canStop, isTrue);
        expect(capabilities.canSeek, isTrue);
      });

      test('radio is live and not seekable or skippable', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 0,
          currentIndex: null,
          isRadioMode: true,
          duration: Duration.zero,
          processingState: AudioProcessingState.ready,
          playing: true,
        );

        expect(capabilities.isLive, isTrue);
        expect(capabilities.canPause, isTrue);
        expect(capabilities.canStop, isTrue);
        expect(capabilities.canSeek, isFalse);
        expect(capabilities.canSkipNext, isFalse);
        expect(capabilities.canSkipPrevious, isFalse);
      });

      test('single-track queue exposes previous to restart current track', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 1,
          currentIndex: 0,
          isRadioMode: false,
          duration: const Duration(minutes: 4),
          processingState: AudioProcessingState.ready,
          playing: false,
        );

        expect(capabilities.canPlay, isTrue);
        expect(capabilities.canPause, isFalse);
        expect(capabilities.canStop, isTrue);
        expect(capabilities.canSeek, isTrue);
        expect(capabilities.canSkipNext, isFalse);
        expect(capabilities.canSkipPrevious, isTrue);
      });

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

      test('middle and edge queue positions expose valid skip directions', () {
        final middle = navisOsControlCapabilities(
          queueLength: 3,
          currentIndex: 1,
          isRadioMode: false,
          duration: const Duration(minutes: 4),
          processingState: AudioProcessingState.ready,
          playing: true,
        );
        expect(middle.canSkipPrevious, isTrue);
        expect(middle.canSkipNext, isTrue);

        final end = navisOsControlCapabilities(
          queueLength: 3,
          currentIndex: 2,
          isRadioMode: false,
          duration: const Duration(minutes: 4),
          processingState: AudioProcessingState.ready,
          playing: true,
        );
        expect(end.canSkipPrevious, isTrue);
        expect(end.canSkipNext, isFalse);
      });

      test('completed playback can be played again and seeked', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 2,
          currentIndex: 1,
          isRadioMode: false,
          duration: const Duration(minutes: 4),
          processingState: AudioProcessingState.completed,
          playing: false,
        );

        expect(capabilities.canPlay, isTrue);
        expect(capabilities.canPause, isFalse);
        expect(capabilities.canSeek, isTrue);
        expect(capabilities.canStop, isTrue);
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

      test('unknown duration media is treated as non-seekable live media', () {
        final capabilities = navisOsControlCapabilities(
          queueLength: 1,
          currentIndex: 0,
          isRadioMode: false,
          duration: Duration.zero,
          processingState: AudioProcessingState.ready,
          playing: true,
        );

        expect(capabilities.canSeek, isFalse);
        expect(capabilities.isLive, isTrue);
      });
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

      test('playlist and title extras use their scoped searches', () {
        expect(
          navisAndroidAutoSearchRequest('', {
            AndroidAutoConstants.mediaPlaylistKey: 'Road',
          }).type,
          NavisAndroidAutoSearchType.playlist,
        );
        expect(
          navisAndroidAutoSearchRequest('', {
            AndroidAutoConstants.mediaTitleKey: 'Feeling Good',
          }).type,
          NavisAndroidAutoSearchType.title,
        );
      });

      test('a genre voice intent is only a raw-query search', () {
        // Genres are not a Navis concept: the platform genre focus and extra
        // are ignored and the spoken query is searched as typed.
        final request = navisAndroidAutoSearchRequest('jazz music', {
          AndroidAutoConstants.mediaFocusKey: 'vnd.android.cursor.item/genre',
          'android.intent.extra.genre': 'Jazz',
        });
        expect(request.type, NavisAndroidAutoSearchType.general);
        expect(request.term, 'jazz music');
      });

      test('plain query uses general search', () {
        final request = navisAndroidAutoSearchRequest('Queen');
        expect(request.type, NavisAndroidAutoSearchType.general);
        expect(request.term, 'Queen');
      });
    });

    group('Android Auto resume source selection', () {
      test('keeps active queue before any fallback', () {
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: true,
            hasPersistedQueue: true,
            hasRecentSongs: true,
            hasLikedSongs: true,
            canUseRandomFallback: true,
          ),
          NavisAutoResumeSource.activeQueue,
        );
      });

      test('prefers persisted, recent, liked, then random fallback', () {
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: false,
            hasPersistedQueue: true,
            hasRecentSongs: true,
            hasLikedSongs: true,
            canUseRandomFallback: true,
          ),
          NavisAutoResumeSource.persistedQueue,
        );
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: false,
            hasPersistedQueue: false,
            hasRecentSongs: true,
            hasLikedSongs: true,
            canUseRandomFallback: true,
          ),
          NavisAutoResumeSource.recentSong,
        );
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: false,
            hasPersistedQueue: false,
            hasRecentSongs: false,
            hasLikedSongs: true,
            canUseRandomFallback: true,
          ),
          NavisAutoResumeSource.likedSong,
        );
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: false,
            hasPersistedQueue: false,
            hasRecentSongs: false,
            hasLikedSongs: false,
            canUseRandomFallback: true,
          ),
          NavisAutoResumeSource.randomFallback,
        );
      });

      test('returns none when no Navis source is available', () {
        expect(
          navisChooseAutoResumeSource(
            hasActiveQueue: false,
            hasPersistedQueue: false,
            hasRecentSongs: false,
            hasLikedSongs: false,
            canUseRandomFallback: false,
          ),
          NavisAutoResumeSource.none,
        );
      });
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
      test('no current index returns none', () {
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 1,
            currentIndex: null,
            position: Duration.zero,
          ),
          NavisPreviousTrackAction.none,
        );
      });

      test('first or single track restarts current', () {
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 1,
            currentIndex: 0,
            position: Duration.zero,
          ),
          NavisPreviousTrackAction.restartCurrent,
        );
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 3,
            currentIndex: 0,
            position: const Duration(seconds: 1),
          ),
          NavisPreviousTrackAction.restartCurrent,
        );
      });

      test('previous exists and position above threshold restarts current', () {
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 3,
            currentIndex: 1,
            position: const Duration(seconds: 3, milliseconds: 1),
          ),
          NavisPreviousTrackAction.restartCurrent,
        );
      });

      test('previous exists and position at or below threshold skips back', () {
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 3,
            currentIndex: 1,
            position: const Duration(seconds: 3),
          ),
          NavisPreviousTrackAction.skipToPrevious,
        );
      });

      test('no previous item restarts at or below threshold', () {
        expect(
          navisResolvePreviousTrackAction(
            queueLength: 2,
            currentIndex: 0,
            position: navisPreviousTrackRestartThreshold,
          ),
          NavisPreviousTrackAction.restartCurrent,
        );
      });
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
