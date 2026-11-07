import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/library/presentation/genre_providers.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/features/player/presentation/replay_gain_untagged_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/fake_playback_handler.dart';
import '../../../../helpers/test_database.dart';

class _Epoch extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final _epochProvider = NotifierProvider<_Epoch, int>(_Epoch.new);

class _Snapshot extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();
  void set(PlaybackSnapshot value) => state = value;
}

final _snapshotProvider = NotifierProvider<_Snapshot, PlaybackSnapshot>(
  _Snapshot.new,
);

/// Answers like the handler: the decision follows the stored mode, and every
/// read is counted.
class _GainHandler extends InertPlaybackHandler {
  _GainHandler(this.decisionFor);

  final ReplayGainDecision? Function() decisionFor;
  int reads = 0;

  @override
  ReplayGainDecision? get currentReplayGainDecision {
    reads++;
    return decisionFor();
  }
}

const _playing = PlaybackSnapshot(
  queueSongIds: <String>['a', 'b'],
  currentSongId: 'a',
  currentIndex: 0,
  playing: true,
  processingState: AudioProcessingState.ready,
  position: Duration.zero,
  duration: Duration(minutes: 3),
  bufferedPosition: Duration.zero,
  shuffleMode: AudioServiceShuffleMode.none,
  repeatMode: AudioServiceRepeatMode.none,
);

ReplayGainDecision _decision(String mode, double? db) => ReplayGainDecision(
  mode: mode,
  resolvedMode: mode == 'smart' ? 'album' : mode,
  db: db,
  source: db == null ? null : ReplayGainSource.album,
);

void main() {
  late NavisDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = createTestDatabase();
    container = ProviderContainer(
      overrides: [
        navisDatabaseProvider.overrideWithValue(db),
        genreDataEpochProvider.overrideWith((ref) => ref.watch(_epochProvider)),
      ],
    );
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> tag(int from, int to, double gain) async {
    await db.batch(
      (batch) => batch.insertAll(db.songsTable, [
        for (var i = from; i < to; i++)
          SongsTableCompanion.insert(
            id: 's$i',
            title: 'Song $i',
            replayGainTrackGain: Value(gain),
          ),
      ]),
    );
  }

  test('with fewer than 20 tagged songs the level is -8 dB', () async {
    await tag(0, 19, -10);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -8);
  });

  test('with 20 tagged songs the level is their median', () async {
    await tag(0, 20, -10);
    await tag(20, 25, 918);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -10);
  });

  test('recomputes after a library sync', () async {
    await tag(0, 20, -10);
    final subscription = container.listen(
      replayGainAutoUntaggedDbProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -10);
    await tag(20, 80, -14);
    container.read(_epochProvider.notifier).bump();
    expect(await container.read(replayGainAutoUntaggedDbProvider.future), -14);
  });

  group('effectiveReplayGainUntaggedDb', () {
    test('a fixed level wins over the library level', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: -5,
          auto: const AsyncData<double>(-9),
        ),
        -5,
      );
    });

    test('Automatic uses the library level', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: null,
          auto: const AsyncData<double>(-9),
        ),
        -9,
      );
    });

    test('a reload keeps the previous library level', () async {
      await tag(0, 20, -10);
      final subscription = container.listen(
        replayGainAutoUntaggedDbProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await container.read(replayGainAutoUntaggedDbProvider.future);
      container.read(_epochProvider.notifier).bump();
      final reloading = container.read(replayGainAutoUntaggedDbProvider);
      expect(reloading.isLoading, isTrue);
      expect(effectiveReplayGainUntaggedDb(fixed: null, auto: reloading), -10);
    });

    test('before the first library level it is -8 dB', () {
      expect(
        effectiveReplayGainUntaggedDb(
          fixed: null,
          auto: const AsyncLoading<double>(),
        ),
        -8,
      );
    });
  });

  group('nowPlayingReplayGainProvider', () {
    late StreamController<AppSettingsModel> settings;
    late String mode;
    late _GainHandler handler;

    ProviderContainer build({NavisPlaybackHandler? withHandler}) {
      final built = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(db),
          genreDataEpochProvider.overrideWith(
            (ref) => ref.watch(_epochProvider),
          ),
          appSettingsProvider.overrideWith((ref) => settings.stream),
          playerStateProvider.overrideWith(
            (ref) => ref.watch(_snapshotProvider),
          ),
          audioHandlerProvider.overrideWithValue(withHandler ?? handler),
        ],
      );
      addTearDown(built.dispose);
      return built;
    }

    Future<void> publish(String next) async {
      mode = next;
      settings.add(
        const AppSettingsModel.defaults().copyWith(replayGainMode: next),
      );
      await Future<void>.delayed(Duration.zero);
    }

    setUp(() {
      settings = StreamController<AppSettingsModel>.broadcast();
      mode = 'smart';
      handler = _GainHandler(
        () => _decision(mode, mode == 'off' ? null : -6.2),
      );
    });
    tearDown(() => settings.close());

    test('is null with no song', () async {
      final c = build();
      final sub = c.listen(nowPlayingReplayGainProvider, (_, _) {});
      addTearDown(sub.close);
      await publish('smart');
      expect(c.read(nowPlayingReplayGainProvider), isNull);
    });

    test('is null with no audio handler', () async {
      final c = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith((ref) => settings.stream),
          playerStateProvider.overrideWithValue(_playing),
          audioHandlerProvider.overrideWithValue(null),
        ],
      );
      addTearDown(c.dispose);
      expect(c.read(nowPlayingReplayGainProvider), isNull);
    });

    test('is the handler decision while a song plays, null when Off', () async {
      final c = build();
      final sub = c.listen(nowPlayingReplayGainProvider, (_, _) {});
      addTearDown(sub.close);
      c.read(_snapshotProvider.notifier).set(_playing);
      await publish('smart');
      expect(c.read(nowPlayingReplayGainProvider)?.db, -6.2);
      await publish('off');
      expect(c.read(nowPlayingReplayGainProvider), isNull);
    });

    test(
      'recomputes when the mode changes and when the song changes',
      () async {
        final c = build();
        final sub = c.listen(nowPlayingReplayGainProvider, (_, _) {});
        addTearDown(sub.close);
        c.read(_snapshotProvider.notifier).set(_playing);
        await publish('smart');
        expect(c.read(nowPlayingReplayGainProvider)?.mode, 'smart');
        await publish('track');
        expect(c.read(nowPlayingReplayGainProvider)?.mode, 'track');
        final reads = handler.reads;
        c
            .read(_snapshotProvider.notifier)
            .set(
              PlaybackSnapshot(
                queueSongIds: _playing.queueSongIds,
                currentSongId: 'b',
                currentIndex: 1,
                playing: true,
                processingState: AudioProcessingState.ready,
                position: Duration.zero,
                duration: const Duration(minutes: 3),
                bufferedPosition: Duration.zero,
                shuffleMode: AudioServiceShuffleMode.none,
                repeatMode: AudioServiceRepeatMode.none,
              ),
            );
        c.read(nowPlayingReplayGainProvider);
        expect(handler.reads, greaterThan(reads));
      },
    );

    test('a position tick does not re-read the handler', () async {
      final c = build();
      final sub = c.listen(nowPlayingReplayGainProvider, (_, _) {});
      addTearDown(sub.close);
      c.read(_snapshotProvider.notifier).set(_playing);
      await publish('smart');
      // Let the Automatic level resolve: that re-asks once, legitimately.
      await c.read(replayGainAutoUntaggedDbProvider.future);
      await Future<void>.delayed(Duration.zero);
      c.read(nowPlayingReplayGainProvider);
      final reads = handler.reads;
      c
          .read(_snapshotProvider.notifier)
          .set(
            PlaybackSnapshot(
              queueSongIds: _playing.queueSongIds,
              currentSongId: 'a',
              currentIndex: 0,
              playing: true,
              processingState: AudioProcessingState.ready,
              position: const Duration(seconds: 30),
              duration: const Duration(minutes: 3),
              bufferedPosition: const Duration(minutes: 1),
              shuffleMode: AudioServiceShuffleMode.none,
              repeatMode: AudioServiceRepeatMode.none,
            ),
          );
      c.read(nowPlayingReplayGainProvider);
      expect(handler.reads, reads);
    });
  });

  test('coverage reports usable songs and the total', () async {
    await tag(0, 3, -10);
    await db
        .into(db.songsTable)
        .insert(SongsTableCompanion.insert(id: 'x', title: 'No gain'));
    final stats = await container.read(replayGainLibraryGainsProvider.future);
    expect(stats.total, 4);
    expect(stats.withData, 3);
  });
}
