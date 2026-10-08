import 'package:navis/src/features/equalizer/domain/eq_configuration.dart';
import 'package:navis/src/features/player/domain/playback_adjustments.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lrclib_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/domain/server_config.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/library/presentation/library_scroll_provider.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/lyrics_resolution.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/settings/data/settings_repository.dart';
import 'package:navis/src/features/settings/data/update_check_store.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../helpers/test_database.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository;

class _MockLrclibClient extends Mock implements LrclibClient;

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

class _MutableServerConfigState
    extends Notifier<AsyncValue<ServerConfigModel?>> {
  @override
  AsyncValue<ServerConfigModel?> build() => const AsyncData(null);

  void set(ServerConfigModel? value) {
    state = AsyncData(value);
  }
}

class _FakePlaybackHandler implements NavisPlaybackHandler {
  @override
  EqCapabilities get equalizerCapabilities => EqCapabilities.unavailable;
  @override
  EqApplicationState get equalizerState => EqApplicationState(
    desired: EqConfiguration.flat(),
    applied: EqConfiguration.flat(),
  );
  @override
  Stream<EqApplicationState> get equalizerStateStream => const Stream.empty();
  @override
  Future<void> setEqualizer(EqConfiguration values) async =>
      throw UnsupportedError('This fake has no EQ backend');
  @override
  Future<void> refreshEqualizerState() async {}

  final StreamController<PlaybackSnapshot> _controller =
      StreamController<PlaybackSnapshot>.broadcast();
  final StreamController<PlaybackBufferState> _bufferController =
      StreamController<PlaybackBufferState>.broadcast();
  final List<List<String>> addToQueueCalls = <List<String>>[];
  final List<List<String>> playNextCalls = <List<String>>[];
  final List<String> retainCurrentSongCalls = <String>[];
  final List<bool> addToQueueExpandFlags = <bool>[];
  final List<bool> playNextExpandFlags = <bool>[];
  final List<double> volumeCalls = <double>[];
  int resetSessionCalls = 0;
  double volume = 1;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot.idle();
  PlaybackBufferState _bufferState = const PlaybackBufferState.idle();

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Stream<PlaybackSnapshot> get snapshotStream => _controller.stream;

  @override
  Stream<Duration> get positionStream => Stream<Duration>.empty();

  @override
  PlaybackBufferState get bufferState => _bufferState;

  @override
  Stream<PlaybackBufferState> get bufferStateStream => _bufferController.stream;

  void emitBufferState(PlaybackBufferState value) {
    _bufferState = value;
    _bufferController.add(value);
  }

  @override
  MediaItem? get currentMediaItem => null;

  @override
  Stream<MediaItem?> get mediaItemStream => const Stream<MediaItem?>.empty();

  @override
  Stream<void> get radioStreamErrorStream => const Stream<void>.empty();

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      const Stream<PlaybackLoadFailure>.empty();

  @override
  Stream<QueueSongsDropped> get droppedSongsStream =>
      const Stream<QueueSongsDropped>.empty();

  @override
  Stream<TransportVisualCue> get transportVisualCueStream =>
      const Stream<TransportVisualCue>.empty();

  @override
  Future<void> waitUntilReady() async {}

  int retryDeferredQueueRestoreCalls = 0;

  @override
  Future<void> retryDeferredQueueRestore() async {
    retryDeferredQueueRestoreCalls++;
  }

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    addToQueueCalls.add(List<String>.from(songIds));
    addToQueueExpandFlags.add(expandMatchFlows);
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
  Future<void> resetSession() async {
    resetSessionCalls++;
    await clearQueue();
  }

  @override
  Future<void> pause() async {
    _snapshot = _snapshot.copyWith(playing: false);
    _controller.add(_snapshot);
  }

  @override
  Future<void> stop() async {
    await pause();
  }

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> applySongIdentityAliases(Map<String, String> aliases) async {}

  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    playNextCalls.add(List<String>.from(songIds));
    playNextExpandFlags.add(expandMatchFlows);
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
  Future<void> retainCurrentSongAsQueue(String songId) async {
    retainCurrentSongCalls.add(songId);
    _snapshot = _snapshot.copyWith(
      queueSongIds: <String>[songId],
      currentSongId: songId,
      currentIndex: 0,
    );
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
    bool expandMatchFlows = true,
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
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {
    final ids = songs.map((s) => s.id).toList(growable: false);
    await replaceQueue(ids, startIndex: startIndex, autoPlay: autoPlay);
  }

  @override
  Future<void> seek(Duration position) async {
    _snapshot = _snapshot.copyWith(position: position);
    _controller.add(_snapshot);
  }

  @override
  Map<String, Object?> collectPlaybackDiagnostics() => <String, Object?>{
    'songId': _snapshot.currentSongId,
    'positionMs': _snapshot.position.inMilliseconds,
    'userVolume': volume,
    'effectivePlayerVolume': volume,
  };

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
  Future<void> setVolume(double volume) async {
    this.volume = volume;
    volumeCalls.add(volume);
  }

  @override
  PlaybackAdjustments get playbackAdjustments => const PlaybackAdjustments();

  @override
  Stream<PlaybackAdjustments> get playbackAdjustmentsStream =>
      const Stream.empty();

  @override
  PlaybackAdjustmentCapabilities get playbackAdjustmentCapabilities =>
      PlaybackAdjustmentCapabilities.android;

  @override
  Future<void> setPlaybackAdjustments(PlaybackAdjustments values) =>
      setPlaybackSpeed(values.speed);

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
    bool replaceMetadata = false,
  }) {}

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}
  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}

  Future<void> dispose() async {
    await _controller.close();
    await _bufferController.close();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettingsModel.defaults());
  });

  group('app providers', () {
    test(
      'desktop volume hydrates, persists mute, and restores audible level',
      () async {
        final handler = _FakePlaybackHandler();
        final repository = _MockSettingsRepository();
        when(
          () => repository.saveDesktopPlaybackVolume(
            volume: any(named: 'volume'),
            lastAudibleVolume: any(named: 'lastAudibleVolume'),
          ),
        ).thenAnswer((_) async {});
        final container = ProviderContainer(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            settingsRepositoryProvider.overrideWithValue(repository),
            desktopVolumePersistenceEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        final controller = container.read(playbackVolumeProvider.notifier);
        controller.hydrate(volume: 0, lastAudibleVolume: 0.37);
        expect(container.read(playbackVolumeProvider), 0);
        expect(controller.hydrated, isTrue);

        expect(await controller.toggleMute(), 0.37);
        expect(handler.volume, 0.37);
        verify(
          () => repository.saveDesktopPlaybackVolume(
            volume: 0.37,
            lastAudibleVolume: 0.37,
          ),
        ).called(1);

        expect(await controller.setVolume(0, persistImmediately: true), 0);
        expect(controller.lastAudibleVolume, 0.37);
        verify(
          () => repository.saveDesktopPlaybackVolume(
            volume: 0,
            lastAudibleVolume: 0.37,
          ),
        ).called(1);
      },
    );

    test('mobile volume remains session-only', () async {
      final handler = _FakePlaybackHandler();
      final repository = _MockSettingsRepository();
      final container = ProviderContainer(
        overrides: [
          audioHandlerProvider.overrideWithValue(handler),
          settingsRepositoryProvider.overrideWithValue(repository),
          desktopVolumePersistenceEnabledProvider.overrideWithValue(false),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      final controller = container.read(playbackVolumeProvider.notifier);
      controller.hydrate(volume: 0.25, lastAudibleVolume: 0.25);
      expect(container.read(playbackVolumeProvider), 1);
      expect(controller.hydrated, isFalse);

      await controller.setVolume(0.42, persistImmediately: true);
      expect(handler.volume, 0.42);
      verifyNever(
        () => repository.saveDesktopPlaybackVolume(
          volume: any(named: 'volume'),
          lastAudibleVolume: any(named: 'lastAudibleVolume'),
        ),
      );
    });

    test(
      'desktop volume coalesces drag persistence to the latest value',
      () async {
        final handler = _FakePlaybackHandler();
        final repository = _MockSettingsRepository();
        when(
          () => repository.saveDesktopPlaybackVolume(
            volume: any(named: 'volume'),
            lastAudibleVolume: any(named: 'lastAudibleVolume'),
          ),
        ).thenAnswer((_) async {});
        final container = ProviderContainer(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            settingsRepositoryProvider.overrideWithValue(repository),
            desktopVolumePersistenceEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        final controller = container.read(playbackVolumeProvider.notifier);
        controller.hydrate(volume: 1, lastAudibleVolume: 1);
        await controller.setVolume(0.2);
        await controller.setVolume(0.4);
        await controller.setVolume(0.6);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        verify(
          () => repository.saveDesktopPlaybackVolume(
            volume: 0.6,
            lastAudibleVolume: 0.6,
          ),
        ).called(1);
        verifyNoMoreInteractions(repository);
      },
    );

    test(
      'desktop volume can surface persistence failures to diagnostics',
      () async {
        final handler = _FakePlaybackHandler();
        final repository = _MockSettingsRepository();
        when(
          () => repository.saveDesktopPlaybackVolume(
            volume: any(named: 'volume'),
            lastAudibleVolume: any(named: 'lastAudibleVolume'),
          ),
        ).thenThrow(StateError('write failed'));
        final container = ProviderContainer(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            settingsRepositoryProvider.overrideWithValue(repository),
            desktopVolumePersistenceEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        final controller = container.read(playbackVolumeProvider.notifier);
        controller.hydrate(volume: 1, lastAudibleVolume: 1);

        await expectLater(
          controller.setVolume(
            0.37,
            persistImmediately: true,
            throwOnPersistenceFailure: true,
          ),
          throwsStateError,
        );
        expect(handler.volume, 0.37);
        expect(container.read(playbackVolumeProvider), 0.37);
      },
    );

    test('playbackBufferStateProvider yields current and live state', () async {
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [audioHandlerProvider.overrideWithValue(handler)],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      final nextState = Completer<PlaybackBufferState>();
      final subscription = container.listen(playbackBufferStateProvider, (
        _,
        next,
      ) {
        final value = next.asData?.value;
        if (value?.songId == 'song-1' && !nextState.isCompleted) {
          nextState.complete(value);
        }
      });
      addTearDown(subscription.close);

      expect(
        await container.read(playbackBufferStateProvider.future),
        isA<PlaybackBufferState>()
            .having((state) => state.songId, 'songId', isNull)
            .having(
              (state) => state.bufferedPosition,
              'bufferedPosition',
              Duration.zero,
            ),
      );

      handler.emitBufferState(
        const PlaybackBufferState(
          songId: 'song-1',
          bufferedPosition: Duration(seconds: 45),
        ),
      );

      expect(
        await nextState.future,
        isA<PlaybackBufferState>()
            .having((state) => state.songId, 'songId', 'song-1')
            .having(
              (state) => state.bufferedPosition,
              'bufferedPosition',
              const Duration(seconds: 45),
            ),
      );
    });

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
                  showAlbumsPage: true,
                  showRadioPage: true,
                  showPlaylistsPage: true,
                  showArtistsPage: true,
                  showLikedPage: true,

                  wifiOnlyDownloads: false,
                  autoDownloadStarredOnWifi: false,
                  customDownloadFolderEnabled: false,
                  customDownloadFolderPath: null,
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
                  libraryPageOrder: null,
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

    test('activeStreamingQualityProvider falls back to defaults when settings unavailable', () async {
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
    });

    test(
      'visibleLibrarySectionsProvider applies custom order and visibility',
      () {
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(
                  showAlbumsPage: false,
                  showArtistsPage: false,
                  showPlaylistsPage: false,
                  libraryPageOrder: <String>[
                    'liked',
                    'albums',
                    'liked',
                    'unknown',
                  ],
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(libraryPageOrderProvider), <LibrarySection>[
          LibrarySection.liked,
          LibrarySection.albums,
          LibrarySection.artists,
          LibrarySection.playlists,
          LibrarySection.radio,
        ]);
        expect(container.read(visibleLibrarySectionsProvider), <LibrarySection>[
          LibrarySection.liked,
          LibrarySection.radio,
        ]);
      },
    );

    test('artistsProvider streams rows from drift database', () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final artistsCompleter = Completer<List<ArtistsTableData>>();
      final container = ProviderContainer(
        overrides: [navisDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final subscription = container.listen<AsyncValue<List<ArtistsTableData>>>(
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

      await database.libraryDao.replaceArtists(<ArtistsTableCompanion>[
        ArtistsTableCompanion.insert(id: 'a1', name: 'Artist 1'),
      ]);

      final artists = await artistsCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      expect(artists.single.id, 'a1');
    }, skip: !sqliteAvailable);

    test('subsonicApiProvider builds client when server config exists', () {
      final database = createTestDatabase();
      addTearDown(database.close);
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
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

    test('subsonicApiProvider keeps its client for sync metadata updates', () {
      final database = createTestDatabase();
      addTearDown(database.close);
      final initial = ServerConfigModel(
        url: 'https://example.com',
        username: 'alice',
        password: 'secret',
        apiVersion: '1.16.1',
      );
      final configState =
          NotifierProvider<
            _MutableServerConfigState,
            AsyncValue<ServerConfigModel?>
          >(_MutableServerConfigState.new);
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          networkTypeProvider.overrideWith((_) => NetworkType.other),
          serverConfigStateProvider.overrideWith(
            (ref) => ref.watch(configState),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(configState.notifier).set(initial);
      final original = container.read(subsonicApiProvider)!;
      container
          .read(configState.notifier)
          .set(
            initial.copyWith(capabilitiesJson: '{"navis":{"lastChecked":1}}'),
          );

      expect(container.read(subsonicApiProvider), same(original));
    });

    test(
      'in-flight API usage survives a network-driven client rebuild',
      () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requestReceived = Completer<HttpRequest>();
        final releaseResponse = Completer<void>();
        server.listen((request) async {
          requestReceived.complete(request);
          await releaseResponse.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(<String, Object>{
              'subsonic-response': <String, Object>{
                'status': 'ok',
                'version': '1.16.1',
                'artists': <String, Object>{
                  'index': <Object>[
                    <String, Object>{
                      'artist': <Object>[
                        <String, Object>{'id': 'artist-1', 'name': 'Artist 1'},
                      ],
                    },
                  ],
                },
              },
            }),
          );
          await request.response.close();
        });
        var networkType = NetworkType.other;
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            networkTypeProvider.overrideWith((_) => networkType),
            serverConfigStateProvider.overrideWithValue(
              AsyncData(
                ServerConfigModel(
                  url: 'http://${server.address.host}:${server.port}',
                  username: 'alice',
                  password: 'secret',
                  apiVersion: '1.16.1',
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final original = container.read(subsonicApiProvider)!;
        final artistsFuture = original.getArtists();
        await requestReceived.future;

        networkType = NetworkType.wifi;
        container.invalidate(networkTypeProvider);
        final replacement = container.read(subsonicApiProvider)!;
        expect(replacement, isNot(same(original)));

        releaseResponse.complete();
        final artists = await artistsFuture;
        expect(artists.single.id, 'artist-1');
      },
      skip: !sqliteAvailable,
    );

    test('queueProvider delegates to playback-backed handler', () async {
      final repository = _MockSettingsRepository();
      final handler = _FakePlaybackHandler();
      when(() => repository.saveSettings(any())).thenAnswer((_) async {});
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
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
      expect(handler.snapshot.queueSongIds, <String>[
        'song-1',
        'song-3',
        'song-2',
      ]);

      await container.read(queueProvider.notifier).reorder(2, 1);
      expect(handler.snapshot.queueSongIds, <String>[
        'song-1',
        'song-2',
        'song-3',
      ]);

      await container.read(queueProvider.notifier).clear();
      expect(handler.snapshot.queueSongIds, isEmpty);
    });

    test('queueProvider replacement reset signal can be suppressed', () async {
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      expect(container.read<int>(regularQueueReplacementEpochProvider), 0);

      await container.read(queueProvider.notifier).replace(<String>[
        'seed',
      ], notifyMixSessionReset: false);
      expect(container.read<int>(regularQueueReplacementEpochProvider), 0);

      await container.read(queueProvider.notifier).replace(<String>['new']);
      expect(container.read<int>(regularQueueReplacementEpochProvider), 1);
    });

    test('queueProvider prewarms lyrics only for a small window', () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final ids = List<String>.generate(50, (index) => 'song-$index');
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        for (final id in ids) SongsTableCompanion.insert(id: id, title: id),
      ]);
      final handler = _FakePlaybackHandler();
      final prewarmed = <String>[];
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((id) async {
            prewarmed.add(id);
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
        await database.close();
      });

      await container.read(queueProvider.notifier).replace(ids, startIndex: 10);

      expect(prewarmed, <String>['song-10', 'song-11', 'song-12']);
    });

    test(
      'queueProvider prewarms lyrics without blocking replacement',
      () async {
        final database = NavisDatabase(NativeDatabase.memory());
        await database.libraryDao.upsertSongs(<SongsTableCompanion>[
          SongsTableCompanion.insert(
            id: 'song-1',
            title: 'Bring Me To Life',
            artistName: const Value('Evanescence'),
          ),
        ]);
        final handler = _FakePlaybackHandler();
        final lrclib = _MockLrclibClient();
        final searchStarted = Completer<void>();
        final releaseSearch = Completer<void>();
        when(
          () => lrclib.searchLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
          ),
        ).thenAnswer((_) async {
          if (!searchStarted.isCompleted) {
            searchStarted.complete();
          }
          await releaseSearch.future;
          return const <LrclibLyrics>[
            LrclibLyrics(
              artistName: 'Evanescence',
              trackName: 'Bring Me To Life',
              syncedLyrics: '[00:01.00]wake me up',
            ),
          ];
        });
        when(
          () => lrclib.getLyrics(
            artist: 'Evanescence',
            title: 'Bring Me To Life',
            album: 'Fallen',
            duration: 235,
          ),
        ).thenAnswer((_) async => null);
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            audioHandlerProvider.overrideWithValue(handler),
            lrclibClientProvider.overrideWithValue(lrclib),
            subsonicApiProvider.overrideWithValue(null),
            appSettingsProvider.overrideWithValue(
              const AsyncData(AppSettingsModel.defaults()),
            ),
            currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
          ],
        );
        addTearDown(() async {
          if (!releaseSearch.isCompleted) {
            releaseSearch.complete();
          }
          container.dispose();
          await handler.dispose();
          await database.close();
        });

        await container
            .read(queueProvider.notifier)
            .replace(<String>['song-1'])
            .timeout(const Duration(seconds: 1));

        expect(handler.snapshot.queueSongIds, <String>['song-1']);
        await searchStarted.future.timeout(const Duration(seconds: 1));
        releaseSearch.complete();
        ExternalLyricsCacheTableData? cached;
        for (var i = 0; i < 20; i++) {
          cached = await database.libraryDao.getExternalLyricsCache('song-1');
          if (cached != null) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(cached?.source, LyricsSource.lrclibSynced.name);
      },
      skip: !sqliteAvailable,
    );

    test('queueProvider clear retains playback adjustments', () async {
      final repository = _MockSettingsRepository();
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repository),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
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

      await container.read(queueProvider.notifier).replace(<String>['song-1']);
      await container.read(queueProvider.notifier).clear();

      expect(handler.snapshot.queueSongIds, isEmpty);
      verifyNever(() => repository.saveSettings(any()));
      expect(
        container.read(appSettingsProvider).requireValue.playbackSpeed,
        1.5,
      );
    });

    test(
      'queueProvider normalizes replace IDs and clamps start index',
      () async {
        final handler = _FakePlaybackHandler();
        final container = ProviderContainer(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            lyricsPrewarmProvider.overrideWithValue((_) async {}),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await handler.dispose();
        });

        await container.read(queueProvider.notifier).replace(<String>[
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

        await container.read(queueProvider.notifier).replace(<String>[
          ' song-4 ',
        ], startIndex: -5);
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
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
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

    test('queueProvider playNextWithSongs persists songs and delegates to playNext', () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
        await database.close();
      });

      await container.read(queueProvider.notifier).replace(<String>[
        'current',
        'later',
      ], startIndex: 0);
      await container.read(queueProvider.notifier).playNextWithSongs(
        const <Song>[
          Song(
            id: ' remote-1 ',
            title: 'Remote 1',
            artist: 'Remote Artist',
            artistId: 'remote-artist',
            album: 'Remote Album',
            albumId: 'remote-album',
          ),
          Song(id: '   ', title: 'Blank ID'),
          Song(id: 'remote-2', title: 'Remote 2'),
        ],
        expandMatchFlows: false,
      );

      expect(handler.playNextCalls, <List<String>>[
        <String>['remote-1', 'remote-2'],
      ]);
      expect(handler.playNextExpandFlags, <bool>[false]);
      expect(handler.snapshot.queueSongIds, <String>[
        'current',
        'remote-1',
        'remote-2',
        'later',
      ]);

      final persisted = await database.libraryDao.getSongsByIds(const <String>[
        'remote-1',
        'remote-2',
      ]);
      expect(persisted.map((song) => song.id), <String>[
        'remote-1',
        'remote-2',
      ]);
      expect(persisted.first.artistId, 'remote-artist');
      expect(persisted.first.albumId, 'remote-album');
    }, skip: !sqliteAvailable);

    test('queueProvider appendMixTracks persists songs and delegates to addToQueue', () async {
      final database = NavisDatabase(NativeDatabase.memory());
      final handler = _FakePlaybackHandler();
      await handler.replaceQueue(<String>['seed']);
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
        await database.close();
      });

      final inserted = await container
          .read(queueProvider.notifier)
          .appendMixTracks(const <Song>[
            Song(
              id: ' rec-1 ',
              title: 'Recommendation 1',
              artist: 'Remote Artist',
              artistId: 'remote-artist',
              album: 'Remote Album',
              albumId: 'remote-album',
            ),
          ], expandMatchFlows: false);

      expect(inserted, 1);
      expect(handler.addToQueueCalls, <List<String>>[
        <String>['rec-1'],
      ]);
      expect(handler.addToQueueExpandFlags, <bool>[false]);
      expect(handler.playNextCalls, isEmpty);
      expect(handler.snapshot.queueSongIds, <String>['seed', 'rec-1']);
    }, skip: !sqliteAvailable);

    test(
      'queueProvider throws explicit unavailable error when handler missing',
      () async {
        final container = ProviderContainer(overrides: []);
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

    test('audio bootstrap transitions to ready when handler initialization succeeds', () async {
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
    });

    test('session reset waits for an in-flight audio bootstrap', () async {
      final initializer = Completer<NavisPlaybackHandler>();
      final handler = _FakePlaybackHandler();
      final container = ProviderContainer(
        overrides: [
          audioHandlerInitializerProvider.overrideWithValue(
            () => initializer.future,
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      container
          .read(audioBootstrapControllerProvider.notifier)
          .ensureInitialized();
      var resetCompleted = false;
      final reset = container
          .read(audioBootstrapControllerProvider.notifier)
          .resetSessionAndWait()
          .then((_) => resetCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(resetCompleted, isFalse);

      initializer.complete(handler);
      await reset;

      expect(resetCompleted, isTrue);
      expect(handler.resetSessionCalls, 1);
    });

    test(
      'bootstrap teardown abandons a stuck initializer and retries fresh',
      () async {
        final stuckInitializer = Completer<NavisPlaybackHandler>();
        final staleHandler = _FakePlaybackHandler();
        final freshHandler = _FakePlaybackHandler();
        var initializerCalls = 0;
        final container = ProviderContainer(
          overrides: [
            audioHandlerInitializerProvider.overrideWithValue(() {
              initializerCalls += 1;
              return initializerCalls == 1
                  ? stuckInitializer.future
                  : Future<NavisPlaybackHandler>.value(freshHandler);
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await staleHandler.dispose();
          await freshHandler.dispose();
        });

        container
            .read(audioBootstrapControllerProvider.notifier)
            .ensureInitialized();
        await Future<void>.delayed(Duration.zero);
        await container
            .read(audioBootstrapControllerProvider.notifier)
            .abortForSessionTeardown();

        expect(
          container.read(audioBootstrapControllerProvider).status,
          AudioBootstrapStatus.failed,
        );
        expect(container.read(audioHandlerStateProvider), isNull);

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        expect(initializerCalls, 2);
        expect(container.read(audioHandlerStateProvider), same(freshHandler));

        stuckInitializer.complete(staleHandler);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(container.read(audioHandlerStateProvider), same(freshHandler));
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

    test('audio bootstrap retries automatically after a failure', () async {
      final handler = _FakePlaybackHandler();
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          audioBootstrapRetryDelayProvider.overrideWith(
            (_) => const Duration(milliseconds: 10),
          ),
          audioHandlerInitializerProvider.overrideWithValue(() async {
            attempts += 1;
            if (attempts <= 2) {
              throw StateError('transient bootstrap failure');
            }
            return handler;
          }),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });

      await container.read(audioBootstrapControllerProvider.notifier).retry();
      expect(
        container.read(audioBootstrapControllerProvider).status,
        AudioBootstrapStatus.failed,
      );
      expect(
        container
            .read(audioBootstrapControllerProvider.notifier)
            .isRetryScheduled,
        isTrue,
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final bootstrap = container.read(audioBootstrapControllerProvider);
      expect(bootstrap.status, AudioBootstrapStatus.ready);
      expect(bootstrap.handler, same(handler));
      expect(bootstrap.attempt, 3);
      expect(attempts, 3);
    });

    test(
      'late timeout recovery cancels the scheduled automatic retry',
      () async {
        final delayedCompleter = Completer<NavisPlaybackHandler>();
        final delayedHandler = _FakePlaybackHandler();
        var attempts = 0;
        final container = ProviderContainer(
          overrides: [
            audioBootstrapTimeoutProvider.overrideWith(
              (_) => const Duration(milliseconds: 5),
            ),
            audioBootstrapRetryDelayProvider.overrideWith(
              (_) => const Duration(milliseconds: 50),
            ),
            audioHandlerInitializerProvider.overrideWithValue(() {
              attempts += 1;
              return delayedCompleter.future;
            }),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await delayedHandler.dispose();
        });

        await container.read(audioBootstrapControllerProvider.notifier).retry();
        expect(
          container
              .read(audioBootstrapControllerProvider.notifier)
              .isRetryScheduled,
          isTrue,
        );

        delayedCompleter.complete(delayedHandler);
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          container.read(audioBootstrapControllerProvider).status,
          AudioBootstrapStatus.ready,
        );
        expect(
          container
              .read(audioBootstrapControllerProvider.notifier)
              .isRetryScheduled,
          isFalse,
        );

        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(attempts, 1);
      },
    );

    test('audio bootstrap cancels a scheduled retry when disposed', () async {
      var attempts = 0;
      final container = ProviderContainer(
        overrides: [
          audioBootstrapRetryDelayProvider.overrideWith(
            (_) => const Duration(milliseconds: 10),
          ),
          audioHandlerInitializerProvider.overrideWithValue(() async {
            attempts += 1;
            throw StateError('bootstrap failure');
          }),
        ],
      );

      await container.read(audioBootstrapControllerProvider.notifier).retry();
      expect(
        container
            .read(audioBootstrapControllerProvider.notifier)
            .isRetryScheduled,
        isTrue,
      );
      container.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(attempts, 1);
    });

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
          overrides: [navisDatabaseProvider.overrideWithValue(database)],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        await database.libraryDao.replaceAlbums(<AlbumsTableCompanion>[
          AlbumsTableCompanion.insert(
            id: 'album-1',
            name: 'Album 1',
            songsHydrated: const Value(false),
          ),
        ]);

        final emittedCounts = <int>[];
        final firstWrite = Completer<void>();
        final completer = Completer<void>();
        final subscription = container.listen<AsyncValue<AlbumWithSongs?>>(
          albumProvider('album-1'),
          (_, next) {
            next.whenData((value) {
              if (value == null) {
                return;
              }
              emittedCounts.add(value.songs.length);
              if (value.songs.length == 1 && !firstWrite.isCompleted) {
                firstWrite.complete();
              }
              if (value.songs.length == 2 && !completer.isCompleted) {
                completer.complete();
              }
            });
          },
          fireImmediately: true,
        );
        addTearDown(subscription.close);

        await database.libraryDao.reconcileSongsForAlbumsChunk({
          'album-1': <SongsTableCompanion>[
            SongsTableCompanion.insert(
              id: 'song-1',
              title: 'Song 1',
              albumId: const Value('album-1'),
            ),
          ],
        });
        // Rapid writes may coalesce into one stream emission; wait until the
        // first write is visible so each write is observed on its own.
        await firstWrite.future.timeout(const Duration(seconds: 5));

        await database.libraryDao.reconcileSongsForAlbumsChunk({
          'album-1': <SongsTableCompanion>[
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
        });

        await completer.future.timeout(const Duration(seconds: 5));
        expect(emittedCounts, contains(1));
        expect(emittedCounts.last, 2);
      },
      skip: !sqliteAvailable,
    );
  });

  group('lyrics lookup metadata helper', () {
    test(
      'falls back to current media item metadata when song row is missing',
      () {
        final metadata = navisResolveLyricsLookupMetadata(
          songId: 'song-1',
          song: null,
          currentMediaItem: const MediaItem(
            id: 'song-1',
            title: 'Track Title',
            artist: 'Artist Name',
            album: 'Album Name',
            duration: Duration(seconds: 245),
          ),
        );

        expect(metadata, isNotNull);
        expect(metadata!.title, 'Track Title');
        expect(metadata.artist, 'Artist Name');
        expect(metadata.album, 'Album Name');
        expect(metadata.durationSeconds, 245);
      },
    );

    test('merges missing song fields from current media item', () {
      final metadata = navisResolveLyricsLookupMetadata(
        songId: 'song-1',
        song: const SongsTableData(
          isProvisional: false,
          isExternal: false,
          id: 'song-1',
          title: 'Track Title',
          artistName: null,
          albumName: null,
          duration: null,
        ),
        currentMediaItem: const MediaItem(
          id: 'song-1',
          title: 'Track Title',
          artist: 'Artist Name',
          album: 'Album Name',
          duration: Duration(seconds: 245),
        ),
      );

      expect(metadata, isNotNull);
      expect(metadata!.title, 'Track Title');
      expect(metadata.artist, 'Artist Name');
      expect(metadata.album, 'Album Name');
      expect(metadata.durationSeconds, 245);
    });

    test('ignores unrelated current media items', () {
      final metadata = navisResolveLyricsLookupMetadata(
        songId: 'song-1',
        song: null,
        currentMediaItem: const MediaItem(
          id: 'song-2',
          title: 'Other Track',
          artist: 'Other Artist',
        ),
      );

      expect(metadata, isNull);
    });
  });

  group('lyricsProvider LRCLIB-first resolution', () {
    Future<NavisDatabase> createLyricsDatabase() async {
      final database = NavisDatabase(NativeDatabase.memory());
      await database.libraryDao.upsertAlbums(<AlbumsTableCompanion>[
        AlbumsTableCompanion.insert(
          id: 'album-1',
          name: 'Fallen',
          artistName: const Value('Evanescence'),
        ),
      ]);
      await database.libraryDao.upsertSongs(<SongsTableCompanion>[
        SongsTableCompanion.insert(
          id: 'song-1',
          title: 'Bring Me To Life',
          albumId: const Value('album-1'),
          artistName: const Value('Evanescence'),
          albumName: const Value('Fallen'),
          duration: const Value(235),
        ),
      ]);
      return database;
    }

    test('searches LRCLIB before server when enabled', () async {
      final database = await createLyricsDatabase();
      final lrclib = _MockLrclibClient();
      final api = _MockSubsonicApiClient();
      when(
        () => lrclib.searchLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
        ),
      ).thenAnswer(
        (_) async => const <LrclibLyrics>[
          LrclibLyrics(
            artistName: 'Evanescence',
            trackName: 'Bring Me To Life',
            albumName: 'Fallen',
            duration: 235,
            syncedLyrics: '[00:01.00]wake me up',
          ),
        ],
      );
      when(
        () => lrclib.getLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        ),
      ).thenAnswer((_) async => null);
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          lrclibClientProvider.overrideWithValue(lrclib),
          subsonicApiProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final resolution = await container.read(lyricsProvider('song-1').future);

      expect(resolution.source, LyricsSource.lrclibSynced);
      verifyNever(() => api.getLyricsBySongId(any()));
      verify(
        () => lrclib.searchLyrics(
          artist: 'Evanescence',
          title: 'Bring Me To Life',
        ),
      ).called(1);
      verifyNever(
        () => lrclib.getLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
          album: any(named: 'album'),
          duration: any(named: 'duration'),
        ),
      );
    }, skip: !sqliteAvailable);

    for (final entry in <String, AppSettingsModel>{
      'the lyrics switch is off': const AppSettingsModel.defaults().copyWith(
        useLrclib: false,
      ),
      'the LRCLIB service is off': const AppSettingsModel.defaults().copyWith(
        disabledIntegrations: '["lrclib"]',
      ),
      'the master switch is off': const AppSettingsModel.defaults().copyWith(
        externalIntegrationsEnabled: false,
      ),
    }.entries) {
      test('never contacts LRCLIB when ${entry.key}', () async {
        final database = await createLyricsDatabase();
        final lrclib = _MockLrclibClient();
        final api = _MockSubsonicApiClient();
        when(() => api.getLyricsBySongId('song-1'))
            .thenAnswer((_) async => const LyricsList(value: 'server lyric'));
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            lrclibClientProvider.overrideWithValue(lrclib),
            subsonicApiProvider.overrideWithValue(api),
            appSettingsProvider.overrideWithValue(AsyncData(entry.value)),
            currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        expect(container.read(useLrclibProvider), isFalse);
        final resolution = await container.read(
          lyricsProvider('song-1').future,
        );

        expect(resolution.source, LyricsSource.serverPlain);
        verifyNever(
          () => lrclib.searchLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
          ),
        );
        verifyNever(
          () => lrclib.getLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
            album: any(named: 'album'),
            duration: any(named: 'duration'),
          ),
        );
      }, skip: !sqliteAvailable);
    }

    test('falls back to server lyrics when LRCLIB throws', () async {
      final database = await createLyricsDatabase();
      final lrclib = _MockLrclibClient();
      final api = _MockSubsonicApiClient();
      when(
        () => lrclib.searchLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
        ),
      ).thenThrow(DioException(requestOptions: RequestOptions()));
      when(() => api.getLyricsBySongId('song-1'))
          .thenAnswer((_) async => const LyricsList(value: 'server lyric'));
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          lrclibClientProvider.overrideWithValue(lrclib),
          subsonicApiProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final resolution = await container.read(lyricsProvider('song-1').future);

      expect(resolution.source, LyricsSource.serverPlain);
      verify(() => api.getLyricsBySongId('song-1')).called(1);
    }, skip: !sqliteAvailable);

    test('returns cached synced lyrics before LRCLIB lookup', () async {
      final database = await createLyricsDatabase();
      final lrclib = _MockLrclibClient();
      final api = _MockSubsonicApiClient();
      await database.libraryDao.upsertExternalLyricsCache(
        songId: 'song-1',
        source: LyricsSource.lrclibSynced.name,
        syncedLyrics: '[00:01.00]cached synced',
      );
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          lrclibClientProvider.overrideWithValue(lrclib),
          subsonicApiProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
          currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final resolution = await container.read(lyricsProvider('song-1').future);

      expect(resolution.source, LyricsSource.lrclibSynced);
      expect(
        resolution.lyrics.structuredLyrics.single.line.single.value,
        'cached synced',
      );
      verifyNever(() => api.getLyricsBySongId(any()));
      verifyNever(
        () => lrclib.searchLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
        ),
      );
    }, skip: !sqliteAvailable);

    test('does not call LRCLIB when disabled', () async {
      final database = await createLyricsDatabase();
      final lrclib = _MockLrclibClient();
      final api = _MockSubsonicApiClient();
      when(() => api.getLyricsBySongId('song-1'))
          .thenAnswer((_) async => const LyricsList(value: 'server lyric'));
      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          lrclibClientProvider.overrideWithValue(lrclib),
          subsonicApiProvider.overrideWithValue(api),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              const AppSettingsModel.defaults().copyWith(useLrclib: false),
            ),
          ),
          currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final resolution = await container.read(lyricsProvider('song-1').future);

      expect(resolution.source, LyricsSource.serverPlain);
      verify(() => api.getLyricsBySongId('song-1')).called(1);
      verifyNever(
        () => lrclib.searchLyrics(
          artist: any(named: 'artist'),
          title: any(named: 'title'),
        ),
      );
    }, skip: !sqliteAvailable);

    test(
      'LRCLIB disabled prefers available server lyrics over LRCLIB cache',
      () async {
        final database = await createLyricsDatabase();
        final lrclib = _MockLrclibClient();
        final api = _MockSubsonicApiClient();
        await database.libraryDao.upsertExternalLyricsCache(
          songId: 'song-1',
          source: LyricsSource.lrclibSynced.name,
          syncedLyrics: '[00:01.00]cached lrclib',
        );
        when(() => api.getLyricsBySongId('song-1'))
            .thenAnswer((_) async => const LyricsList(value: 'server lyric'));
        final container = ProviderContainer(
          overrides: [
            navisDatabaseProvider.overrideWithValue(database),
            lrclibClientProvider.overrideWithValue(lrclib),
            subsonicApiProvider.overrideWithValue(api),
            appSettingsProvider.overrideWithValue(
              AsyncData(
                const AppSettingsModel.defaults().copyWith(useLrclib: false),
              ),
            ),
            currentMediaItemProvider.overrideWithValue(const AsyncData(null)),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });

        final resolution = await container.read(
          lyricsProvider('song-1').future,
        );

        expect(resolution.source, LyricsSource.serverPlain);
        expect(resolution.lyrics.value, 'server lyric');
        verify(() => api.getLyricsBySongId('song-1')).called(1);
        verifyNever(
          () => lrclib.searchLyrics(
            artist: any(named: 'artist'),
            title: any(named: 'title'),
          ),
        );
      },
      skip: !sqliteAvailable,
    );
  });

  group('preferredMixModeProvider', () {
    test('forces legacy mode when no Last.fm API key is available', () {
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue(''),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(preferredMixModeProvider),
        PreferredMixMode.legacyInstantMix,
      );
    });

    test('uses legacy mode when setting is enabled', () {
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(preferredMixModeProvider),
        PreferredMixMode.legacyInstantMix,
      );
    });

    test('uses same vibes when setting is disabled and key is available', () {
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWithValue(
            AsyncData(
              AppSettingsModel.defaults().copyWith(
                legacyInstantMixEnabled: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(preferredMixModeProvider),
        PreferredMixMode.sameVibes,
      );
    });
  });

  group('integrationPolicyProvider', () {
    ProviderContainer containerFor(
      AsyncValue<AppSettingsModel> settings, {
      String lastFmKey = 'test-key',
    }) {
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue(lastFmKey),
          appSettingsProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('denies everything while settings load or fail', () {
      for (final settings in <AsyncValue<AppSettingsModel>>[
        const AsyncLoading<AppSettingsModel>(),
        AsyncError<AppSettingsModel>('boom', StackTrace.empty),
      ]) {
        final policy = containerFor(settings).read(integrationPolicyProvider);
        for (final feature in IntegrationFeature.values) {
          expect(policy.allows(feature), isFalse, reason: feature.key);
        }
      }
    });

    test('follows stored settings once loaded', () {
      final policy = containerFor(
        AsyncData(
          const AppSettingsModel.defaults().copyWith(
            disabledIntegrations: '["deezer.topSongs"]',
            useLrclib: false,
            listenBrainzTokenValid: true,
          ),
        ),
      ).read(integrationPolicyProvider);
      expect(policy.allows(IntegrationFeature.deezerTopSongs), isFalse);
      expect(policy.allows(IntegrationFeature.deezerTrending), isTrue);
      expect(policy.allows(IntegrationFeature.lrclibLyrics), isFalse);
      expect(policy.allows(IntegrationFeature.lastFmRadio), isTrue);
      expect(policy.allows(IntegrationFeature.listenBrainzFeedback), isTrue);
    });

    test('Last.fm needs a key and ListenBrainz needs a valid token', () {
      final policy = containerFor(
        AsyncData(const AppSettingsModel.defaults()),
        lastFmKey: '',
      ).read(integrationPolicyProvider);
      expect(policy.allows(IntegrationFeature.lastFmRadio), isFalse);
      expect(policy.allows(IntegrationFeature.listenBrainzFeedback), isFalse);
      expect(policy.allows(IntegrationFeature.deezerTrending), isTrue);
    });

    test('master off denies even verified services', () {
      final policy = containerFor(
        AsyncData(
          const AppSettingsModel.defaults().copyWith(
            externalIntegrationsEnabled: false,
          ),
        ),
      ).read(integrationPolicyProvider);
      for (final feature in IntegrationFeature.values) {
        expect(policy.allows(feature), isFalse, reason: feature.key);
      }
    });

    test('unrelated settings changes do not notify listeners', () async {
      final controller = StreamController<AppSettingsModel>();
      addTearDown(controller.close);
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue('test-key'),
          appSettingsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);
      final seen = <IntegrationPolicy>[];
      container.listen(
        integrationPolicyProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );

      controller.add(const AppSettingsModel.defaults());
      await pumpEventQueue();
      controller.add(
        const AppSettingsModel.defaults().copyWith(themeMode: 'light'),
      );
      await pumpEventQueue();
      controller.add(
        const AppSettingsModel.defaults().copyWith(
          disabledIntegrations: '["radio"]',
        ),
      );
      await pumpEventQueue();

      // Loading (denyAll), loaded, then the radio change; the theme change
      // produced no new policy.
      expect(seen.length, 3);
      expect(seen[0], const IntegrationPolicy.denyAll());
      expect(seen[2].allows(IntegrationFeature.radioNowPlaying), isFalse);
    });
  });

  group('preferredMixModeProvider and the policy', () {
    PreferredMixMode modeFor(
      AsyncValue<AppSettingsModel> settings, {
      String key = 'test-key',
    }) {
      final container = ProviderContainer(
        overrides: [
          lastFmApiKeyProvider.overrideWithValue(key),
          appSettingsProvider.overrideWithValue(settings),
        ],
      );
      addTearDown(container.dispose);
      return container.read(preferredMixModeProvider);
    }

    test('is the server mix while settings load', () {
      expect(
        modeFor(const AsyncLoading<AppSettingsModel>()),
        PreferredMixMode.legacyInstantMix,
      );
    });

    test('follows the lastfm.sameVibes switch, stored inverted', () {
      expect(
        modeFor(AsyncData(const AppSettingsModel.defaults())),
        PreferredMixMode.sameVibes,
      );
      expect(
        modeFor(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              legacyInstantMixEnabled: true,
            ),
          ),
        ),
        PreferredMixMode.legacyInstantMix,
      );
    });

    test('is the server mix when the Last.fm service or master is off', () {
      expect(
        modeFor(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              disabledIntegrations: '["lastfm"]',
            ),
          ),
        ),
        PreferredMixMode.legacyInstantMix,
      );
      expect(
        modeFor(
          AsyncData(
            const AppSettingsModel.defaults().copyWith(
              externalIntegrationsEnabled: false,
            ),
          ),
        ),
        PreferredMixMode.legacyInstantMix,
      );
    });
  });

  group('updateProvider', () {
    test(
      'unrelated settings and policy changes do not rerun updates',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final settings = StreamController<AppSettingsModel>();
        addTearDown(settings.close);
        final store = _RecordingUpdateCheckStore();
        final container = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith((ref) => settings.stream),
            updateCheckStoreProvider.overrideWithValue(store),
          ],
        );
        addTearDown(container.dispose);
        container.listen(appSettingsProvider, (_, _) {});
        settings.add(const AppSettingsModel.defaults());
        await container.read(appSettingsProvider.future);
        container.listen(updateProvider, (_, _) {});
        await container.read(updateProvider.future);
        expect(store.forceArguments, [false]);
        settings.add(
          const AppSettingsModel.defaults().copyWith(
            disabledIntegrations: '["deezer"]',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await container.read(updateProvider.future);
        expect(store.forceArguments, [false]);
      },
    );

    test('returns null when auto update checks are disabled', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final settings = const AppSettingsModel.defaults().copyWith(
        updateCheckEnabled: false,
      );
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith((ref) => Stream.value(settings)),
          updateCheckStoreProvider.overrideWithValue(_NoOpUpdateCheckStore()),
        ],
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(Duration.zero);

      expect(await container.read(updateProvider.future), isNull);
    });

    Future<List<bool>> checksFor(
      AppSettingsModel settings, {
      required bool force,
    }) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final store = _RecordingUpdateCheckStore();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith((ref) => Stream.value(settings)),
          updateCheckStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      container.listen(appSettingsProvider, (_, _) {});
      await container.read(appSettingsProvider.future);
      if (force) {
        container.read(updateForceCheckProvider.notifier).requestForceCheck();
      }
      await container.read(updateProvider.future);
      return store.forceArguments;
    }

    test('Check now works while automatic checks are off', () async {
      final settings = const AppSettingsModel.defaults().copyWith(
        updateCheckEnabled: false,
      );
      expect(await checksFor(settings, force: true), [true]);
      // Without the manual request, the automatic switch still blocks it.
      expect(await checksFor(settings, force: false), isEmpty);
    });

    test('automatic checks run when on', () async {
      expect(await checksFor(const AppSettingsModel.defaults(), force: false), [
        false,
      ]);
    });

    test(
      'the updates service and master switch still block Check now',
      () async {
        for (final settings in [
          const AppSettingsModel.defaults().copyWith(
            disabledIntegrations: '["updates"]',
          ),
          const AppSettingsModel.defaults().copyWith(
            externalIntegrationsEnabled: false,
          ),
        ]) {
          expect(await checksFor(settings, force: true), isEmpty);
        }
      },
    );

    test('a blocked check still consumes the manual request', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final container = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            (ref) => Stream.value(
              const AppSettingsModel.defaults().copyWith(
                externalIntegrationsEnabled: false,
              ),
            ),
          ),
          updateCheckStoreProvider.overrideWithValue(
            _RecordingUpdateCheckStore(),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(appSettingsProvider, (_, _) {});
      await container.read(appSettingsProvider.future);
      container.read(updateForceCheckProvider.notifier).requestForceCheck();
      await container.read(updateProvider.future);
      expect(
        container.read(updateForceCheckProvider.notifier).consumeForceCheck(),
        isFalse,
      );
    });
  });
}

class _RecordingUpdateCheckStore extends UpdateCheckStore {
  final List<bool> forceArguments = <bool>[];

  /// Declines the check, so nothing reaches the network.
  @override
  Future<bool> shouldCheck({bool force = false}) async {
    forceArguments.add(force);
    return false;
  }

  @override
  Future<void> recordCheck([DateTime? checkedAt]) async {}
}

class _NoOpUpdateCheckStore extends UpdateCheckStore {
  @override
  Future<bool> shouldCheck({bool force = false}) async => true;

  @override
  Future<void> recordCheck([DateTime? checkedAt]) async {}
}
