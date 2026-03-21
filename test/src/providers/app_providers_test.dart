import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/api/subsonic_auth_interceptor.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';
import '../../helpers/test_database.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

class _FakePlaybackHandler implements NavisPlaybackHandler {
  final StreamController<PlaybackSnapshot> _controller =
      StreamController<PlaybackSnapshot>.broadcast();
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _controller.stream;

  @override
  Stream<Duration> get positionStream => Stream<Duration>.empty();

  @override
  MediaItem? get currentMediaItem => null;

  @override
  Stream<MediaItem?> get mediaItemStream => const Stream<MediaItem?>.empty();

  @override
  Stream<void> get radioStreamErrorStream => const Stream<void>.empty();

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      const Stream<ManualTrackChangeCue>.empty();

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> addToQueue(List<String> songIds) async {
    _snapshot = _snapshot.copyWith(
      queueSongIds: <String>[..._snapshot.queueSongIds, ...songIds],
    );
    _controller.add(_snapshot);
  }

  @override
  Future<void> clearQueue() async {
    _snapshot = const PlaybackSnapshot.idle();
    _controller.add(_snapshot);
  }

  @override
  Future<void> pause() async {
    _snapshot = _snapshot.copyWith(playing: false);
    _controller.add(_snapshot);
  }

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> playNext(List<String> songIds) async {
    if (songIds.isEmpty) {
      return;
    }
    final queue = <String>[..._snapshot.queueSongIds];
    final currentIndex = (_snapshot.currentIndex ?? -1).clamp(-1, queue.length);
    final insertAt = currentIndex + 1;
    queue.insertAll(insertAt, songIds);
    _snapshot = _snapshot.copyWith(queueSongIds: queue);
    _controller.add(_snapshot);
  }

  @override
  Future<void> play() async {
    _snapshot = _snapshot.copyWith(playing: true);
    _controller.add(_snapshot);
  }

  @override
  Future<void> playFromIndex(int index) async {
    final currentSongId = index >= 0 && index < _snapshot.queueSongIds.length
        ? _snapshot.queueSongIds[index]
        : null;
    _snapshot = _snapshot.copyWith(
      currentIndex: index,
      currentSongId: currentSongId,
    );
    _controller.add(_snapshot);
  }

  @override
  Future<void> removeAt(int index) async {
    final queue = <String>[..._snapshot.queueSongIds];
    if (index < 0 || index >= queue.length) {
      return;
    }
    queue.removeAt(index);
    _snapshot = _snapshot.copyWith(queueSongIds: queue);
    _controller.add(_snapshot);
  }

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    final queue = <String>[..._snapshot.queueSongIds];
    if (oldIndex < 0 || oldIndex >= queue.length) {
      return;
    }
    if (newIndex < 0 || newIndex >= queue.length) {
      return;
    }
    if (oldIndex == newIndex) {
      return;
    }
    final moved = queue.removeAt(oldIndex);
    final adjusted = oldIndex < newIndex ? newIndex - 1 : newIndex;
    queue.insert(adjusted, moved);
    _snapshot = _snapshot.copyWith(queueSongIds: queue);
    _controller.add(_snapshot);
  }

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
  }) async {
    final current = songIds.isEmpty
        ? null
        : songIds[startIndex.clamp(0, songIds.length - 1)];
    _snapshot = PlaybackSnapshot(
      queueSongIds: List<String>.unmodifiable(songIds),
      currentSongId: current,
      currentIndex: songIds.isEmpty ? null : startIndex,
      playing: autoPlay && songIds.isNotEmpty,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: Duration.zero,
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
    );
    _controller.add(_snapshot);
  }

  @override
  Future<void> seek(Duration position) async {
    _snapshot = _snapshot.copyWith(position: position);
    _controller.add(_snapshot);
  }

  @override
  Future<void> skipToNext() async {
    final idx = (_snapshot.currentIndex ?? -1) + 1;
    if (idx < _snapshot.queueSongIds.length) {
      await playFromIndex(idx);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final idx = (_snapshot.currentIndex ?? 1) - 1;
    if (idx >= 0) {
      await playFromIndex(idx);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _snapshot = _snapshot.copyWith(shuffleMode: shuffleMode);
    _controller.add(_snapshot);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _snapshot = _snapshot.copyWith(repeatMode: repeatMode);
    _controller.add(_snapshot);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> toggleLike() async {
    final liked = !_snapshot.isCurrentSongLiked;
    _snapshot = _snapshot.copyWith(isCurrentSongLiked: liked);
    _controller.add(_snapshot);
  }

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {
    _snapshot = _snapshot.copyWith(isCurrentSongLiked: liked);
    _controller.add(_snapshot);
  }

  @override
  Future<void> playRadioStream({
    required String stationId,
    required String stationName,
    required String streamUrl,
    String? homePageUrl,
  }) async {}

  @override
  Future<void> stopRadio() async {}

  @override
  void updateRadioMetadata({
    String? title,
    String? artist,
    String? artUrl,
  }) {}

  Future<void> dispose() async {
    await _controller.close();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  group('app providers', () {
    test('subsonicApiProvider returns null when server config missing', () {
      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(subsonicApiProvider), isNull);
    });

    test('subsonicApiProvider returns null when password is unavailable', () {
      final container = ProviderContainer(
        overrides: [
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: '',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(subsonicApiProvider), isNull);
    });

    test(
      'network and streaming quality providers use persisted settings profiles',
      () async {
        final container = ProviderContainer(
          overrides: [
            networkTypeProvider.overrideWith((_) => NetworkType.cellular),
            appSettingsProvider.overrideWithValue(
              const AsyncData(
                AppSettingsModel(
                  wifiMaxBitRate: null,
                  wifiFormat: null,
                  cellularMaxBitRate: 128,
                  cellularFormat: 'aac',
                  scrobbleEnabled: true,
                  gaplessEnabled: true,
                  skipSilenceEnabled: false,
                  showRadioPage: true,
                  showPlaylistsPage: true,
                  showArtistsPage: true,
                  showLikedPage: true,
                  equalizerEnabled: false,
                  equalizerBandGains: <double>[],
                  loudnessEnabled: false,
                  loudnessTargetGainDb: 0,
                  wifiOnlyDownloads: false,
                  autoDownloadStarredOnWifi: false,
                  themeMode: 'dark',
                  colorSchemeSeed: null,
                  appLocale: null,
                  crossfadeEnabled: false,
                  crossfadeDurationSeconds: 5,
                  crossfadeType: 'normal',
                  artTintedNowPlaying: true,
                  dynamicAlbumColorEnabled: false,
                  updateCheckEnabled: true,
                  updateChannel: 'stable',
                  audioMuseServerUrl: null,
                  audioMuseApiKey: null,
                  audioMuseEnabled: false,
                  syncIntervalMinutes: 60,
                  useLrclib: true,
                  legacyInstantMixEnabled: false,
                  replayGainMode: 'off',
                  replayGainPreamp: 0,
                  playbackSpeed: 1,
                  albumGridDensity: null,
                  coverArtShape: 'rounded',
                  nowPlayingArtShape: 'rounded',
                  artistCardShape: 'circle',
                  artistViewMode: 'grid',
                  homeSectionOrder: null,
                  homeSectionsHidden: null,
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(networkTypeProvider), NetworkType.cellular);
        final quality = container.read(activeStreamingQualityProvider);
        expect(quality.maxBitRate, 128);
        expect(quality.format, 'aac');
      },
    );

    test(
      'activeStreamingQualityProvider falls back to defaults when settings unavailable',
      () async {
        final container = ProviderContainer(
          overrides: [
            networkTypeProvider.overrideWith((_) => NetworkType.cellular),
            appSettingsProvider.overrideWithValue(
              const AsyncLoading<AppSettingsModel>(),
            ),
          ],
        );
        addTearDown(container.dispose);

        final quality = container.read(activeStreamingQualityProvider);
        expect(quality.maxBitRate, 192);
        expect(quality.format, 'opus');
      },
    );

    test(
      'artistsProvider streams rows from drift database',
      () async {
        final database = NavisDatabase(NativeDatabase.memory());
        final artistsCompleter = Completer<List<ArtistsTableData>>();
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        final subscription = container
            .listen<AsyncValue<List<ArtistsTableData>>>(
              artistsProvider,
              (_, next) {
                next.whenData((artists) {
                  if (artists.isNotEmpty && !artistsCompleter.isCompleted) {
                    artistsCompleter.complete(artists);
                  }
                });
              },
              fireImmediately: true,
            );
        addTearDown(subscription.close);

        await database.libraryDao.replaceArtists(
          <ArtistsTableCompanion>[
            ArtistsTableCompanion.insert(id: 'a1', name: 'Artist 1'),
          ],
        );

        final artists = await artistsCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        expect(artists.single.id, 'a1');
      },
      skip: !sqliteAvailable,
    );

    test('subsonicApiProvider builds client when server config exists', () {
      final container = ProviderContainer(
        overrides: [
          networkTypeProvider.overrideWith((_) => NetworkType.other),
          serverConfigStateProvider.overrideWithValue(
            const AsyncData(
              ServerConfigModel(
                url: 'https://example.com',
                username: 'alice',
                password: 'secret',
                apiVersion: '1.16.1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(subsonicApiProvider), isNotNull);
    });

    test('searchResultsProvider uses live search API path', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      final client = SubsonicApiClient(
        baseUrl: 'https://example.com',
        authConfig: const SubsonicAuthConfig(
          username: 'alice',
          password: 'secret',
          apiVersion: '1.16.1',
        ),
        dio: dio,
        enableLogging: false,
      );

      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/rest/search3.view') {
              handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: <String, dynamic>{
                    'subsonic-response': <String, dynamic>{
                      'status': 'ok',
                      'searchResult3': <String, dynamic>{
                        'artist': <Map<String, dynamic>>[
                          <String, dynamic>{'id': 'a1', 'name': 'Artist 1'},
                        ],
                      },
                    },
                  },
                ),
              );
              return;
            }
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.badResponse,
              ),
            );
          },
        ),
      );

      final container = ProviderContainer(
        overrides: [
          subsonicApiProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(
        searchResultsProvider('hello').future,
      );
      expect(result.artists.single.id, 'a1');
      expect(result.albums, isEmpty);
      expect(result.songs, isEmpty);
    });

    test('queueProvider delegates to playback-backed handler', () async {
      final repository = _MockSettingsRepository();
      final handler = _FakePlaybackHandler();
      when(() => repository.saveSettings(any())).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          audioHandlerProvider.overrideWithValue(handler),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      await container.read(queueProvider.notifier).replace(<String>['song-1']);
      expect(handler.snapshot.queueSongIds, <String>['song-1']);

      await container.read(queueProvider.notifier).add(' song-2 ');
      expect(handler.snapshot.queueSongIds, <String>['song-1', 'song-2']);

      await container.read(queueProvider.notifier).playNext(' song-3 ');
      expect(
        handler.snapshot.queueSongIds,
        <String>['song-1', 'song-3', 'song-2'],
      );

      await container.read(queueProvider.notifier).reorder(2, 1);
      expect(
        handler.snapshot.queueSongIds,
        <String>['song-1', 'song-2', 'song-3'],
      );

      await container.read(queueProvider.notifier).clear();
      expect(handler.snapshot.queueSongIds, isEmpty);
    });

    test(
      'queueProvider clear resets persisted playback speed to 1.0',
      () async {
        final repository = _MockSettingsRepository();
        final handler = _FakePlaybackHandler();
        AppSettingsModel? savedSettings;
        when(
          () => repository.saveSettings(any()),
        ).thenAnswer((invocation) async {
          savedSettings =
              invocation.positionalArguments.first as AppSettingsModel;
        });
        final container = ProviderContainer(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(repository),
            audioHandlerProvider.overrideWithValue(handler),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(playbackSpeed: 1.5),
              ),
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        await container.read(queueProvider.notifier).replace(<String>[
          'song-1',
        ]);
        await container.read(queueProvider.notifier).clear();

        expect(handler.snapshot.queueSongIds, isEmpty);
        verify(() => repository.saveSettings(any())).called(1);
        expect(savedSettings, isNotNull);
        expect(savedSettings!.playbackSpeed, 1);
      },
    );

    test(
      'queueProvider normalizes replace IDs and clamps start index',
      () async {
        final handler = _FakePlaybackHandler();
        final container = ProviderContainer(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        await container
            .read(
              queueProvider.notifier,
            )
            .replace(<String>[
              '  ',
              ' song-1 ',
              '',
              'song-2  ',
            ], startIndex: 99);

        expect(handler.snapshot.queueSongIds, <String>['song-1', 'song-2']);
        expect(handler.snapshot.currentIndex, 1);
        expect(handler.snapshot.currentSongId, 'song-2');

        await container.read(queueProvider.notifier).replace(<String>[
          '   ',
          '',
        ], startIndex: 0);
        expect(handler.snapshot.queueSongIds, isEmpty);

        await container
            .read(
              queueProvider.notifier,
            )
            .replace(<String>[' song-4 '], startIndex: -5);
        expect(handler.snapshot.queueSongIds, <String>['song-4']);
        expect(handler.snapshot.currentIndex, 0);
        expect(handler.snapshot.currentSongId, 'song-4');
      },
    );

    test('queueProvider ignores blank add and playNext input', () async {
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          audioHandlerProvider.overrideWithValue(handler),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      await container.read(queueProvider.notifier).replace(<String>[
        'song-1',
      ], startIndex: 0);
      await container.read(queueProvider.notifier).add('   ');
      await container.read(queueProvider.notifier).playNext('   ');

      expect(handler.snapshot.queueSongIds, <String>['song-1']);
    });

    test(
      'queueProvider throws explicit unavailable error when handler missing',
      () async {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await expectLater(
          container.read(queueProvider.notifier).replace(<String>['song-1']),
          throwsA(
            isA<PlaybackUnavailableException>().having(
              (error) => error.reason,
              'reason',
              PlaybackUnavailableReason.initializing,
            ),
          ),
        );
      },
    );

    test(
      'audio bootstrap transitions to ready when handler initialization succeeds',
      () async {
        final handler = _FakePlaybackHandler();
        final container = ProviderContainer(
          overrides: [
            audioHandlerInitializerProvider.overrideWithValue(() async {
              return handler;
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        final bootstrap = container.read(audioBootstrapControllerProvider);

        expect(bootstrap.status, AudioBootstrapStatus.ready);
        expect(bootstrap.handler, same(handler));
        expect(bootstrap.attempt, 1);
        expect(bootstrap.timedOut, isFalse);
        expect(bootstrap.recoveredFromTimeout, isFalse);
        expect(bootstrap.elapsedMs, isNotNull);
        expect(container.read(audioHandlerStateProvider), same(handler));
      },
    );

    test(
      'audio bootstrap timeout can recover when initialization completes late',
      () async {
        final delayedCompleter = Completer<NavisPlaybackHandler>();
        final delayedHandler = _FakePlaybackHandler();

        final container = ProviderContainer(
          overrides: [
            audioBootstrapTimeoutProvider.overrideWith(
              (_) => const Duration(milliseconds: 20),
            ),
            audioHandlerInitializerProvider.overrideWithValue(
              () => delayedCompleter.future,
            ),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await delayedHandler.dispose();
        });

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        final failedState = container.read(audioBootstrapControllerProvider);
        expect(failedState.status, AudioBootstrapStatus.failed);
        expect(failedState.attempt, 1);
        expect(failedState.timedOut, isTrue);
        expect(failedState.recoveredFromTimeout, isFalse);
        expect(failedState.elapsedMs, isNotNull);

        delayedCompleter.complete(delayedHandler);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final recovered = container.read(audioBootstrapControllerProvider);
        expect(recovered.status, AudioBootstrapStatus.ready);
        expect(recovered.handler, same(delayedHandler));
        expect(recovered.attempt, 1);
        expect(recovered.timedOut, isFalse);
        expect(recovered.recoveredFromTimeout, isTrue);
        expect(recovered.elapsedMs, isNotNull);
      },
    );

    test(
      'audio bootstrap records non-timeout initialization failures',
      () async {
        final container = ProviderContainer(
          overrides: [
            audioHandlerInitializerProvider.overrideWithValue(() async {
              throw StateError('bootstrap init failed');
            }),
          ],
        );
        addTearDown(container.dispose);

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        final failed = container.read(audioBootstrapControllerProvider);

        expect(failed.status, AudioBootstrapStatus.failed);
        expect(failed.attempt, 1);
        expect(failed.timedOut, isFalse);
        expect(failed.recoveredFromTimeout, isFalse);
        expect(failed.elapsedMs, isNotNull);
        expect(failed.errorMessage, 'Playback initialization failed.');
      },
    );

    test(
      'audio bootstrap ignores stale completion after a newer retry succeeds',
      () async {
        final staleCompleter = Completer<NavisPlaybackHandler>();
        final staleHandler = _FakePlaybackHandler();
        final nextHandler = _FakePlaybackHandler();
        var attempt = 0;

        final container = ProviderContainer(
          overrides: [
            audioBootstrapTimeoutProvider.overrideWith(
              (_) => const Duration(milliseconds: 20),
            ),
            audioHandlerInitializerProvider.overrideWithValue(() {
              attempt += 1;
              if (attempt == 1) {
                return staleCompleter.future;
              }
              return Future<NavisPlaybackHandler>.value(nextHandler);
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await staleHandler.dispose();
          await nextHandler.dispose();
        });

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        expect(
          container.read(audioBootstrapControllerProvider).status,
          AudioBootstrapStatus.failed,
        );

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        final bootstrap = container.read(audioBootstrapControllerProvider);
        expect(bootstrap.status, AudioBootstrapStatus.ready);
        expect(bootstrap.handler, same(nextHandler));

        staleCompleter.complete(staleHandler);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final afterStaleCompletion = container.read(
          audioBootstrapControllerProvider,
        );
        expect(afterStaleCompletion.status, AudioBootstrapStatus.ready);
        expect(afterStaleCompletion.handler, same(nextHandler));
      },
    );

    test(
      'albumProvider emits updated songs when hydration writes new rows',
      () async {
        final database = NavisDatabase(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        await database.libraryDao.replaceAlbums(
          <AlbumsTableCompanion>[
            AlbumsTableCompanion.insert(
              id: 'album-1',
              name: 'Album 1',
              songsHydrated: const Value(false),
            ),
          ],
        );

        final emittedCounts = <int>[];
        final completer = Completer<void>();
        final subscription = container.listen<AsyncValue<AlbumWithSongs?>>(
          albumProvider('album-1'),
          (_, next) {
            next.whenData((value) {
              if (value == null) {
                return;
              }
              emittedCounts.add(value.songs.length);
              if (value.songs.length == 2 && !completer.isCompleted) {
                completer.complete();
              }
            });
          },
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await database.libraryDao.replaceSongsForAlbum(
          'album-1',
          <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-1'),
            ),
          ],
        );

        await database.libraryDao.replaceSongsForAlbum(
          'album-1',
          <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-1'),
            ),
            SongsTableCompanion.insert(
              id: 'song-2',
              title: 'Song 2',
              albumId: const Value('album-1'),
            ),
          ],
        );

        await completer.future.timeout(const Duration(seconds: 5));
        expect(emittedCounts, contains(1));
        expect(emittedCounts.last, 2);
      },
      skip: !sqliteAvailable,
    );
  });
}
