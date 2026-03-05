import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
