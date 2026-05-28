import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/audiomuse/data/audiomuse_repository.dart';
import 'package:navis/src/features/audiomuse/domain/audiomuse_models.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/instant_mix_notifier.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void setSnapshot(PlaybackSnapshot snapshot) {
    state = snapshot;
  }
}

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient {}

class _MockAudioMuseRepository extends Mock implements AudioMuseRepository {}

class _RecordingPlaybackHandler implements NavisPlaybackHandler {
  final List<List<String>> addToQueueCalls = <List<String>>[];
  final List<List<String>> playNextCalls = <List<String>>[];
  final List<bool> addToQueueExpandFlags = <bool>[];
  final List<bool> playNextExpandFlags = <bool>[];

  @override
  PlaybackSnapshot get snapshot => const PlaybackSnapshot.idle();

  @override
  Stream<PlaybackSnapshot> get snapshotStream =>
      const Stream<PlaybackSnapshot>.empty();

  @override
  Stream<ManualTrackChangeCue> get manualTrackChangeCueStream =>
      const Stream<ManualTrackChangeCue>.empty();

  @override
  Stream<Duration> get positionStream => const Stream<Duration>.empty();

  @override
  MediaItem? get currentMediaItem => null;

  @override
  Stream<MediaItem?> get mediaItemStream => const Stream<MediaItem?>.empty();

  @override
  Stream<PlaybackLoadFailure> get loadFailureStream =>
      const Stream<PlaybackLoadFailure>.empty();

  @override
  Stream<void> get radioStreamErrorStream => const Stream<void>.empty();

  @override
  Future<void> waitUntilReady() async {}

  @override
  Future<void> replaceQueue(
    List<String> songIds, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> replaceQueueWithData(
    List<SongsTableData> songs, {
    int startIndex = 0,
    bool autoPlay = true,
    bool expandMatchFlows = true,
  }) async {}

  @override
  Future<void> addToQueue(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    addToQueueCalls.add(List<String>.from(songIds));
    addToQueueExpandFlags.add(expandMatchFlows);
  }

  @override
  Future<void> playNext(
    List<String> songIds, {
    bool expandMatchFlows = true,
  }) async {
    playNextCalls.add(List<String>.from(songIds));
    playNextExpandFlags.add(expandMatchFlows);
  }

  @override
  Future<void> playFromIndex(int index) async {}

  @override
  Future<void> removeAt(int index) async {}

  @override
  Future<void> reorderQueue(int oldIndex, int newIndex) async {}

  @override
  Future<void> clearQueue() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> skipToPrevious() async {}

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {}

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {}

  @override
  Future<void> setPlaybackSpeed(double speed) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> applyRuntimeSettings() async {}

  @override
  Future<void> toggleLike() async {}

  @override
  Future<void> syncSongLikedState(String songId, {required bool liked}) async {}

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

  @override
  void registerPreferredMixCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}

  @override
  void registerPreferredMixToggleCallback(
    Future<void> Function(String seedSongId) callback,
  ) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PlaybackSnapshot snapshot({
    required List<String> queueSongIds,
    required String? currentSongId,
    required int? currentIndex,
    bool radioMode = false,
  }) {
    return PlaybackSnapshot(
      queueSongIds: queueSongIds,
      currentSongId: currentSongId,
      currentIndex: currentIndex,
      playing: true,
      processingState: AudioProcessingState.ready,
      position: Duration.zero,
      duration: const Duration(minutes: 3),
      bufferedPosition: Duration.zero,
      shuffleMode: AudioServiceShuffleMode.none,
      repeatMode: AudioServiceRepeatMode.none,
      radioStation: radioMode
          ? const RadioStationMetadata(
              stationId: 'station-1',
              stationName: 'Test Station',
              streamUrl: 'https://example.com/stream',
            )
          : null,
    );
  }

  test('deactivates when queue is cleared', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['a', 'b', 'c', 'd'],
            currentSongId: 'a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('a');

    container
        .read(snapshotState.notifier)
        .setSnapshot(
          const PlaybackSnapshot.idle(),
        );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(instantMixProvider);
    expect(state.active, isFalse);
    expect(state.seedSongId, isNull);
  });

  test(
    'initial activation inserts Subsonic recommendations with playNext',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      final handler = _RecordingPlaybackHandler();
      when(
        () => api.getSimilarSongs(any()),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'rec-1', title: 'Rec 1'),
          Song(id: 'rec-2', title: 'Rec 2'),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          audioHandlerProvider.overrideWithValue(handler),
          subsonicApiProvider.overrideWithValue(api),
          audioMuseRepositoryProvider.overrideWith((_) => null),
          appSettingsProvider.overrideWithValue(
            const AsyncData(AppSettingsModel.defaults()),
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .setSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'queued'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(instantMixProvider.notifier).activate('seed');

      expect(handler.playNextCalls, <List<String>>[
        <String>['rec-1', 'rec-2'],
      ]);
      expect(handler.playNextExpandFlags, <bool>[false]);
      expect(handler.addToQueueCalls, isEmpty);
    },
  );

  test('AudioMuse recommendations insert with playNext', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final audioMuse = _MockAudioMuseRepository();
    final handler = _RecordingPlaybackHandler();
    when(
      () => audioMuse.getRecommendations(
        seedSongId: any(named: 'seedSongId'),
      ),
    ).thenAnswer(
      (_) async => const <AudioMuseRecommendation>[
        AudioMuseRecommendation(id: 'ai-1', title: 'AI 1'),
        AudioMuseRecommendation(id: 'ai-2', title: 'AI 2'),
      ],
    );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(handler),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWithValue(audioMuse),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'queued'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(instantMixProvider.notifier).activate('seed');

    expect(handler.playNextCalls, <List<String>>[
      <String>['ai-1', 'ai-2'],
    ]);
    expect(handler.playNextExpandFlags, <bool>[false]);
    expect(handler.addToQueueCalls, isEmpty);
  });

  test('auto-refill path updates seed when remaining tracks <= 3', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd', 'e'],
            currentSongId: 'seed-a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('seed-a');

    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-b',
            currentIndex: 0,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(instantMixProvider);
    expect(state.active, isTrue);
    expect(state.seedSongId, 'seed-b');
  });

  test('does not auto-refill while radio mode is active', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        audioHandlerProvider.overrideWithValue(null),
        subsonicApiProvider.overrideWith((_) => null),
        audioMuseRepositoryProvider.overrideWith((_) => null),
        appSettingsProvider.overrideWithValue(
          const AsyncData(AppSettingsModel.defaults()),
        ),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(instantMixProvider.notifier);
    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-a',
            currentIndex: 0,
          ),
        );
    await notifier.activate('seed-a');

    container
        .read(snapshotState.notifier)
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed-a', 'b', 'c', 'd'],
            currentSongId: 'seed-radio',
            currentIndex: 0,
            radioMode: true,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final state = container.read(instantMixProvider);
    expect(state.seedSongId, 'seed-a');
  });
}
