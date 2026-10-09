import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void emitSnapshot(PlaybackSnapshot snapshot, [Object? marker]) {
    state = snapshot;
  }
}

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient;

class _MockLastFmApiClient extends Mock implements LastFmApiClient;

class _FakeQueueController extends QueueController {
  new({this.insertedCount, this.error, this.onRetain});

  final List<List<Song>> appendedSongBatches = <List<Song>>[];
  final List<String> retainedSongIds = <String>[];
  final int? insertedCount;
  final Exception? error;
  final void Function(String id)? onRetain;

  List<Song> get queuedSongs =>
      appendedSongBatches.expand((songs) => songs).toList(growable: false);

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> retainCurrentAsQueue(String id) async {
    retainedSongIds.add(id);
    onRetain?.call(id);
  }

  @override
  Future<RecommendationQueueResult> appendRecommendationTracks(
    List<Song> songs, {
    bool expandMatchFlows = false,
    bool Function()? isCurrent,
  }) async {
    if (isCurrent != null && !isCurrent()) {
      return const RecommendationQueueResult(<String>[]);
    }
    appendedSongBatches.add(List<Song>.from(songs));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final count = insertedCount ?? songs.length;
    return RecommendationQueueResult(
      songs.take(count).map((song) => song.id).toList(),
    );
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

  test('queue identity keeps Japanese and English editions distinct', () {
    final jp = sameVibesCanonicalSongKey(
      'ONE OK ROCK',
      'Wonder (Japanese Version)',
    );
    final en = sameVibesCanonicalSongKey(
      'ONE OK ROCK',
      'Wonder (English Version)',
    );
    expect(jp, isNot(en));
    expect(
      sameVibesCanonicalSongKey(
        'ONE OK ROCK',
        'Wonder (Japanese Version) [Remastered]',
      ),
      jp,
    );
  });

  group('integration policy gate', () {
    for (final entry in <String, IntegrationPolicy>{
      'the Same Vibes switch is off': const IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'lastfm.sameVibes'},
      ),
      'the Last.fm service is off': const IntegrationPolicy(
        lastFmVerified: true,
        disabledKeys: {'lastfm'},
      ),
      'the master switch is off': const IntegrationPolicy(
        lastFmVerified: true,
        masterEnabled: false,
      ),
      'no Last.fm key is verified': const IntegrationPolicy(),
    }.entries) {
      test('never calls Last.fm when ${entry.key}', () async {
        final snapshotState =
            NotifierProvider<_SnapshotController, PlaybackSnapshot>(
              _SnapshotController.new,
            );
        final api = _MockSubsonicApiClient();
        final lastFm = _MockLastFmApiClient();
        when(
          () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
        ).thenAnswer(
          (_) async =>
              const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
        );
        when(
          () => api.getSimilarSongs(
            any(),
            count: any(named: 'count'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer((_) async => const <Song>[]);
        final container = ProviderContainer(
          overrides: [
            playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
            queueProvider.overrideWith(
              () => _FakeQueueController(insertedCount: 1),
            ),
            subsonicApiProvider.overrideWithValue(api),
            lastFmApiClientProvider.overrideWithValue(lastFm),
            integrationPolicyProvider.overrideWithValue(entry.value),
            currentMediaItemProvider.overrideWith(
              (ref) => Stream<MediaItem?>.value(
                const MediaItem(
                  id: 'seed',
                  title: 'Seed Song',
                  artist: 'Seed Artist',
                ),
              ),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{}),
            ),
            cachedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{}),
            ),
            sameVibesAlbumSongCountLookupProvider.overrideWithValue(
              (albumIds) async => const <String, int?>{},
            ),
            sameVibesQueueSongKeyLookupProvider.overrideWithValue(
              (songIds) async => const <String>{},
            ),
          ],
        );
        addTearDown(container.dispose);
        container
            .read(snapshotState.notifier)
            .emitSnapshot(
              snapshot(
                queueSongIds: const <String>['seed'],
                currentSongId: 'seed',
                currentIndex: 0,
              ),
            );

        await container.read(sameVibesProvider.notifier).activate('seed');

        verifyNever(
          () => lastFm.getSimilarTracksResult(
            artist: any(named: 'artist'),
            track: any(named: 'track'),
            limit: any(named: 'limit'),
          ),
        );
      });
    }
  });

  test('deactivates when a regular queue replacement starts', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    late final ProviderContainer container;
    container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(
          () => _FakeQueueController(
            onRetain: (id) {
              container
                  .read(snapshotState.notifier)
                  .emitSnapshot(
                    snapshot(
                      queueSongIds: <String>[id],
                      currentSongId: id,
                      currentIndex: 0,
                    ),
                  );
            },
          ),
        ),
        subsonicApiProvider.overrideWith((_) => null),
        lastFmApiClientProvider.overrideWith((_) => null),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );
    await container.read(sameVibesProvider.notifier).activate('seed');
    expect(container.read(sameVibesProvider).active, isTrue);

    container.read(regularQueueReplacementEpochProvider.notifier).bump();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(sameVibesProvider).active, isFalse);
  });

  test(
    'activation maps Last.fm recommendations and queues mapped songs',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );

      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'ArtistA',
              title: 'SongA',
              match: 1,
            ),
            LastFmTrackRecommendation(
              artist: 'ArtistB',
              title: 'SongB',
              match: 1,
            ),
            LastFmTrackRecommendation(
              artist: 'ArtistC',
              title: 'SongC',
              match: 1,
            ),
            LastFmTrackRecommendation(
              artist: 'ArtistD',
              title: 'SongD',
              match: 1,
            ),
            LastFmTrackRecommendation(
              artist: 'ArtistE',
              title: 'SongE',
              match: 1,
            ),
          ],
        ),
      );

      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer((invocation) async {
        final query = invocation.namedArguments[#query] as String;
        final parts = query.split(' ');
        final artist = parts.first;
        final title = parts.last;
        return SearchResult3(
          songs: <Song>[
            Song(id: '$artist-$title', title: title, artist: artist),
          ],
        );
      });

      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);

      late final ProviderContainer container;
      container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(
            () => _FakeQueueController(
              onRetain: (id) {
                container
                    .read(snapshotState.notifier)
                    .emitSnapshot(
                      snapshot(
                        queueSongIds: <String>[id],
                        currentSongId: id,
                        currentIndex: 0,
                      ),
                    );
              },
            ),
          ),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b', 'c'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      final state = container.read(sameVibesProvider);
      expect(queued.retainedSongIds, <String>['seed']);
      expect(queued.queuedSongs, hasLength(5));
      expect(queued.appendedSongBatches, hasLength(1));
      expect(queued.appendedSongBatches.single.map((song) => song.id), <String>[
        'ArtistA-SongA',
        'ArtistB-SongB',
        'ArtistC-SongC',
        'ArtistD-SongD',
        'ArtistE-SongE',
      ]);
      expect(state.active, isTrue);
      expect(state.pendingSnackbar, '5');
      verify(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: 20,
        ),
      ).called(1);
      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test('activation treats partial queue insertion as success', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );
    final api = _MockSubsonicApiClient();
    final lastFm = _MockLastFmApiClient();
    when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async =>
              const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
        );
    when(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.success,
        tracks: <LastFmTrackRecommendation>[
          LastFmTrackRecommendation(
            artist: 'ArtistA',
            title: 'SongA',
            match: 1,
          ),
          LastFmTrackRecommendation(
            artist: 'ArtistB',
            title: 'SongB',
            match: 0.9,
          ),
          LastFmTrackRecommendation(
            artist: 'ArtistC',
            title: 'SongC',
            match: 0.8,
          ),
        ],
      ),
    );
    when(
      () => api.search3(
        query: any(named: 'query'),
        artistCount: any(named: 'artistCount'),
        albumCount: any(named: 'albumCount'),
        songCount: any(named: 'songCount'),
        artistOffset: any(named: 'artistOffset'),
        albumOffset: any(named: 'albumOffset'),
        songOffset: any(named: 'songOffset'),
      ),
    ).thenAnswer(
      (_) async => const SearchResult3(
        songs: <Song>[
          Song(id: 'mapped-1', title: 'SongA', artist: 'ArtistA'),
          Song(id: 'mapped-2', title: 'SongB', artist: 'ArtistB'),
          Song(id: 'mapped-3', title: 'SongC', artist: 'ArtistC'),
        ],
      ),
    );
    when(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => const <Song>[]);

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(
          () => _FakeQueueController(insertedCount: 1),
        ),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiClientProvider.overrideWithValue(lastFm),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        currentMediaItemProvider.overrideWith(
          (ref) => Stream<MediaItem?>.value(
            const MediaItem(
              id: 'seed',
              title: 'Seed Song',
              artist: 'Seed Artist',
            ),
          ),
        ),
        downloadedSongIdsProvider.overrideWithValue(
          const AsyncData(<String>{}),
        ),
        cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
        sameVibesAlbumSongCountLookupProvider.overrideWithValue(
          (albumIds) async => const <String, int?>{},
        ),
        sameVibesQueueSongKeyLookupProvider.overrideWithValue(
          (songIds) async => const <String>{},
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(sameVibesProvider.notifier).activate('seed');
    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'mapped-1'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );
    await Future<void>.delayed(Duration.zero);

    final queued =
        container.read(queueProvider.notifier) as _FakeQueueController;
    final state = container.read(sameVibesProvider);
    expect(queued.retainedSongIds, <String>['seed']);
    // Three songs were offered but only one was inserted: that still counts
    // as success, and the reported count is the inserted one.
    expect(queued.appendedSongBatches, hasLength(1));
    expect(queued.appendedSongBatches.single.length, greaterThan(1));
    expect(state.active, isTrue);
    expect(state.error, isNull);
    expect(state.pendingSnackbar, '1');
    final session = container.read(recommendationSessionProvider);
    expect(session.stage, 'active');
    expect(session.insertedCount, 1);
    expect(session.candidateCount, queued.appendedSongBatches.single.length);
  });

  test(
    'activation with zero inserted tracks fails once and deactivates',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'ArtistA',
              title: 'SongA',
              match: 1,
            ),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer(
        (_) async => const SearchResult3(
          songs: <Song>[
            Song(id: 'mapped-1', title: 'SongA', artist: 'ArtistA'),
          ],
        ),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(
            () => _FakeQueueController(insertedCount: 0),
          ),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );
      await Future<void>.delayed(Duration.zero);

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      final state = container.read(sameVibesProvider);
      expect(queued.appendedSongBatches, hasLength(1));
      expect(state.active, isFalse);
      expect(state.error, SameVibesError.networkError);
      // The session ends instead of reading "preparing" forever.
      final session = container.read(recommendationSessionProvider);
      expect(session.stage, 'failed');
      expect(session.insertedCount, 0);
    },
  );

  test('activation caps Last.fm mapping at five queued songs', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final api = _MockSubsonicApiClient();
    final lastFm = _MockLastFmApiClient();
    when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async =>
              const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
        );

    when(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.success,
        tracks: List<LastFmTrackRecommendation>.generate(
          8,
          (index) => LastFmTrackRecommendation(
            artist: 'Artist$index',
            title: 'Song$index',
            match: 1,
          ),
          growable: false,
        ),
      ),
    );

    when(
      () => api.search3(
        query: any(named: 'query'),
        artistCount: any(named: 'artistCount'),
        albumCount: any(named: 'albumCount'),
        songCount: any(named: 'songCount'),
        artistOffset: any(named: 'artistOffset'),
        albumOffset: any(named: 'albumOffset'),
        songOffset: any(named: 'songOffset'),
      ),
    ).thenAnswer((invocation) async {
      final query = invocation.namedArguments[#query] as String;
      final parts = query.split(' ');
      final artist = parts.first;
      final title = parts.last;
      return SearchResult3(
        songs: <Song>[Song(id: '$artist-$title', title: title, artist: artist)],
      );
    });

    when(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => const <Song>[]);

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiClientProvider.overrideWithValue(lastFm),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        currentMediaItemProvider.overrideWith(
          (ref) => Stream<MediaItem?>.value(
            const MediaItem(
              id: 'seed',
              title: 'Seed Song',
              artist: 'Seed Artist',
            ),
          ),
        ),
        downloadedSongIdsProvider.overrideWithValue(
          const AsyncData(<String>{}),
        ),
        cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
        sameVibesAlbumSongCountLookupProvider.overrideWithValue(
          (albumIds) async => const <String, int?>{},
        ),
        sameVibesQueueSongKeyLookupProvider.overrideWithValue(
          (songIds) async => const <String>{},
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'a', 'b', 'c'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(sameVibesProvider.notifier).activate('seed');

    final queued =
        container.read(queueProvider.notifier) as _FakeQueueController;
    expect(queued.queuedSongs, hasLength(5));
    verify(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: 20,
      ),
    ).called(1);
  });

  test(
    'falls back to Subsonic similar songs when Last.fm mapping is weak',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );

      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(artist: 'Unknown', title: 'Unknown Song'),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer((_) async => const SearchResult3());
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'fallback-1', title: 'Fallback 1', artist: 'Artist 1'),
          Song(id: 'fallback-2', title: 'Fallback 2', artist: 'Artist 2'),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queued.appendedSongBatches, hasLength(1));
      expect(queued.queuedSongs.map((song) => song.id), contains('fallback-1'));
      expect(queued.queuedSongs.map((song) => song.id), contains('fallback-2'));
      verify(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  test(
    'falls back to Subsonic when Last.fm has transient network failure',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.networkError,
          tracks: <LastFmTrackRecommendation>[],
        ),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'fallback-1', title: 'Fallback 1', artist: 'Artist 1'),
          Song(id: 'fallback-2', title: 'Fallback 2', artist: 'Artist 2'),
          Song(id: 'fallback-3', title: 'Fallback 3', artist: 'Artist 3'),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final state = container.read(sameVibesProvider);
      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(state.active, isTrue);
      expect(state.refilling, isFalse);
      expect(state.error, isNull);
      expect(queued.queuedSongs.map((song) => song.id), <String>[
        'fallback-1',
        'fallback-2',
        'fallback-3',
      ]);
      verify(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(1);
    },
  );

  test(
    'broadens Last.fm mapping before filling remaining slots with fallback',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'Local Artist',
              title: 'Deep Cut',
              match: 1,
            ),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer((invocation) async {
        final query = invocation.namedArguments[#query] as String;
        if (query == 'Deep Cut') {
          return const SearchResult3(
            songs: <Song>[
              Song(
                id: 'mapped-broad',
                title: 'Deep Cut',
                artist: 'Local Artist',
              ),
            ],
          );
        }
        return const SearchResult3();
      });
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'fallback-1', title: 'Fallback 1', artist: 'Artist 1'),
          Song(id: 'fallback-2', title: 'Fallback 2', artist: 'Artist 2'),
          Song(id: 'fallback-3', title: 'Fallback 3', artist: 'Artist 3'),
          Song(id: 'fallback-4', title: 'Fallback 4', artist: 'Artist 4'),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queued.appendedSongBatches.single.map((song) => song.id), <String>[
        'mapped-broad',
        'fallback-1',
        'fallback-2',
        'fallback-3',
        'fallback-4',
      ]);
      verify(
        () => api.search3(
          query: 'Deep Cut',
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).called(1);
    },
  );

  test('skips Subsonic fallback for external seed ids when no server-like seed is available', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final api = _MockSubsonicApiClient();
    final lastFm = _MockLastFmApiClient();
    when(
      () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (_) async =>
          const Song(id: 'ext-seed', title: 'Seed Song', artist: 'Seed Artist'),
    );
    when(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.noResults,
        tracks: <LastFmTrackRecommendation>[],
      ),
    );
    when(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => const <Song>[]);

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiClientProvider.overrideWithValue(lastFm),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        currentMediaItemProvider.overrideWith(
          (ref) => Stream<MediaItem?>.value(
            const MediaItem(
              id: 'ext-seed',
              title: 'Seed Song',
              artist: 'Seed Artist',
            ),
          ),
        ),
        downloadedSongIdsProvider.overrideWithValue(
          const AsyncData(<String>{}),
        ),
        cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
        sameVibesAlbumSongCountLookupProvider.overrideWithValue(
          (albumIds) async => const <String, int?>{},
        ),
        sameVibesQueueSongKeyLookupProvider.overrideWithValue(
          (songIds) async => const <String>{},
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>[
              'ext-seed',
              'ext-other-1',
              'ext-other-2',
            ],
            currentSongId: 'ext-seed',
            currentIndex: 0,
          ),
        );

    await container.read(sameVibesProvider.notifier).activate('ext-seed');

    final state = container.read(sameVibesProvider);
    expect(state.active, isFalse);
    expect(state.refilling, isFalse);
    expect(state.error, SameVibesError.networkError);
    verifyNever(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
  });

  test(
    'prefers album-backed candidate over single-style duplicate match',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );

      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'ArtistA',
              title: 'SongA',
              match: 1,
            ),
          ],
        ),
      );

      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer(
        (_) async => const SearchResult3(
          songs: <Song>[
            Song(
              id: 'single-candidate',
              title: 'SongA',
              artist: 'ArtistA',
              albumId: 'single-album',
              album: 'SongA',
            ),
            Song(
              id: 'album-candidate',
              title: 'SongA',
              artist: 'ArtistA',
              albumId: 'full-album',
              album: 'The Full Album',
            ),
          ],
        ),
      );

      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b', 'c'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queued.queuedSongs, hasLength(1));
      expect(queued.queuedSongs.single.id, 'album-candidate');
    },
  );

  test('does not auto-refill while radio mode is active', () async {
    final snapshotState =
        NotifierProvider<_SnapshotController, PlaybackSnapshot>(
          _SnapshotController.new,
        );

    final api = _MockSubsonicApiClient();
    final lastFm = _MockLastFmApiClient();
    when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async =>
              const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
        );

    when(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer(
      (_) async => const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.noResults,
        tracks: <LastFmTrackRecommendation>[],
      ),
    );
    when(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => const <Song>[]);

    final container = ProviderContainer(
      overrides: [
        playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
        queueProvider.overrideWith(_FakeQueueController.new),
        subsonicApiProvider.overrideWithValue(api),
        lastFmApiClientProvider.overrideWithValue(lastFm),
        integrationPolicyProvider.overrideWithValue(
          const IntegrationPolicy(lastFmVerified: true),
        ),
        currentMediaItemProvider.overrideWith(
          (ref) => Stream<MediaItem?>.value(
            const MediaItem(
              id: 'seed',
              title: 'Seed Song',
              artist: 'Seed Artist',
            ),
          ),
        ),
        downloadedSongIdsProvider.overrideWithValue(
          const AsyncData(<String>{}),
        ),
        cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
        sameVibesAlbumSongCountLookupProvider.overrideWithValue(
          (albumIds) async => const <String, int?>{},
        ),
        sameVibesQueueSongKeyLookupProvider.overrideWithValue(
          (songIds) async => const <String>{},
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'a', 'b', 'c'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(sameVibesProvider.notifier).activate('seed');

    container
        .read(snapshotState.notifier)
        .emitSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'a', 'b', 'c'],
            currentSongId: 'seed-radio',
            currentIndex: 0,
            radioMode: true,
          ),
        );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    verify(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).called(1);
  });

  test(
    'prefers downloaded match when duplicate candidates are otherwise equal',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );

      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'Artist A',
              title: 'Track A',
              match: 1,
            ),
          ],
        ),
      );

      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer(
        (_) async => const SearchResult3(
          songs: <Song>[
            Song(id: 'remote-variant', title: 'Track A', artist: 'Artist A'),
            Song(
              id: 'downloaded-variant',
              title: 'Track A',
              artist: 'Artist A',
            ),
          ],
        ),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{'downloaded-variant'}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b', 'c'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(
        queued.queuedSongs.any((song) => song.id == 'downloaded-variant'),
        isTrue,
      );
      expect(
        queued.queuedSongs.any((song) => song.id == 'remote-variant'),
        isFalse,
      );
    },
  );

  test(
    'batches mapped songs before fallback songs in one queue append',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );

      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'Mapped Artist',
              title: 'Mapped Song',
              match: 1,
            ),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer(
        (_) async => const SearchResult3(
          songs: <Song>[
            Song(id: 'mapped-1', title: 'Mapped Song', artist: 'Mapped Artist'),
          ],
        ),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'mapped-1', title: 'Mapped Song', artist: 'Mapped Artist'),
          Song(id: 'fallback-1', title: 'Fallback 1', artist: 'Artist 1'),
          Song(id: 'fallback-2', title: 'Fallback 2', artist: 'Artist 2'),
        ],
      );

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);

      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
      expect(queued.appendedSongBatches, hasLength(1));
      expect(queued.appendedSongBatches.single.map((song) => song.id), <String>[
        'mapped-1',
        'fallback-1',
        'fallback-2',
      ]);
    },
  );

  group('language versions', () {
    Future<List<String>> mapRecommendation({
      required String title,
      required List<Song> searchResults,
    }) async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(any(), cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async =>
            const Song(id: 'seed', title: 'Seed Song', artist: 'Seed Artist'),
      );
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'ONE OK ROCK',
              title: title,
              match: 1,
            ),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer((_) async => SearchResult3(songs: searchResults));
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              const MediaItem(
                id: 'seed',
                title: 'Seed Song',
                artist: 'Seed Artist',
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: const <String>['seed'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');
      final queue =
          container.read(queueProvider.notifier) as _FakeQueueController;
      return queue.queuedSongs.map((song) => song.id).toList();
    }

    const plain = Song(id: 'plain', title: 'Wonder', artist: 'ONE OK ROCK');
    const japanese = Song(
      id: 'jp',
      title: 'Wonder (Japanese Version)',
      artist: 'ONE OK ROCK',
    );

    test(
      'a Japanese-version recommendation maps to the Japanese song',
      () async {
        expect(
          await mapRecommendation(
            title: 'Wonder (Japanese Version)',
            searchResults: const <Song>[plain, japanese],
          ),
          <String>['jp'],
        );
      },
    );

    test(
      'a below-threshold same-edition tie cannot displace a passing match',
      () async {
        expect(
          await mapRecommendation(
            title: 'Wonder (Japanese Version)',
            searchResults: const [
              Song(
                id: 'passing',
                title: 'Wonder',
                artist: 'ONE FOUR FIVE SIX SEVEN EIGHT NINE',
              ),
              Song(
                id: 'weak',
                title: 'Wonder (Japanese Version)',
                artist: 'ONE FOUR FIVE SIX SEVEN EIGHT NINE TEN',
              ),
            ],
          ),
          ['passing'],
        );
      },
    );

    test('a plain recommendation maps to the plain song', () async {
      expect(
        await mapRecommendation(
          title: 'Wonder',
          searchResults: const <Song>[japanese, plain],
        ),
        <String>['plain'],
      );
    });
  });

  group('the requested seed', () {
    late _MockSubsonicApiClient api;
    late _MockLastFmApiClient lastFm;

    const playingSong = Song(
      id: 'local-1',
      title: 'Local Song',
      artist: 'Local Artist',
    );
    const remoteSeed = Song(
      id: 'ext-deezer-song-1',
      title: 'Dystopia',
      artist: 'ONE OK ROCK',
    );

    setUp(() {
      api = _MockSubsonicApiClient();
      lastFm = _MockLastFmApiClient();
      when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
          .thenAnswer((invocation) async {
            final id = invocation.positionalArguments.first as String;
            return id == remoteSeed.id ? remoteSeed : playingSong;
          });
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.noResults,
          tracks: <LastFmTrackRecommendation>[],
        ),
      );
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[]);
    });

    /// A container whose player is on [queue]'s [current] song.
    ProviderContainer playing({
      required List<String> queue,
      required String current,
      String currentTitle = 'Local Song',
      String currentArtist = 'Local Artist',
    }) {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );
      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
          integrationPolicyProvider.overrideWithValue(
            const IntegrationPolicy(lastFmVerified: true),
          ),
          currentMediaItemProvider.overrideWith(
            (ref) => Stream<MediaItem?>.value(
              MediaItem(
                id: current,
                title: currentTitle,
                artist: currentArtist,
              ),
            ),
          ),
          downloadedSongIdsProvider.overrideWithValue(
            const AsyncData(<String>{}),
          ),
          cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
          sameVibesAlbumSongCountLookupProvider.overrideWithValue(
            (albumIds) async => const <String, int?>{},
          ),
          sameVibesQueueSongKeyLookupProvider.overrideWithValue(
            (songIds) async => const <String>{},
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(currentMediaItemProvider, (_, _) {});
      container
          .read(snapshotState.notifier)
          .emitSnapshot(
            snapshot(
              queueSongIds: queue,
              currentSongId: current,
              currentIndex: queue.indexOf(current),
            ),
          );
      return container;
    }

    _FakeQueueController queueOf(ProviderContainer container) =>
        container.read(queueProvider.notifier) as _FakeQueueController;

    test(
      'the merged queue retains both Japanese and English editions',
      () async {
        when(
          () => api.getSimilarSongs(
            any(),
            count: any(named: 'count'),
            cancelToken: any(named: 'cancelToken'),
          ),
        ).thenAnswer(
          (_) async => const [
            Song(
              id: 'jp',
              title: 'Wonder (Japanese Version)',
              artist: 'ONE OK ROCK',
            ),
            Song(
              id: 'en',
              title: 'Wonder (English Version)',
              artist: 'ONE OK ROCK',
            ),
            Song(
              id: 'jp-remaster',
              title: 'Wonder (Japanese Version) [Remastered]',
              artist: 'ONE OK ROCK',
            ),
          ],
        );
        final container = playing(queue: const ['local-1'], current: 'local-1');
        await container.read(sameVibesProvider.notifier).activate('local-1');
        expect(queueOf(container).queuedSongs.map((song) => song.id), [
          'jp',
          'en',
        ]);
      },
    );

    test('starts from the requested song while another song plays', () async {
      when(
        () => lastFm.getSimilarTracksResult(
          artist: 'ONE OK ROCK',
          track: 'Dystopia',
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.success,
          tracks: <LastFmTrackRecommendation>[
            LastFmTrackRecommendation(
              artist: 'Coldrain',
              title: 'Gone',
              match: 1,
            ),
          ],
        ),
      );
      when(
        () => api.search3(
          query: any(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).thenAnswer(
        (_) async => const SearchResult3(
          songs: <Song>[Song(id: 'gone', title: 'Gone', artist: 'Coldrain')],
        ),
      );
      final container = playing(
        queue: const <String>['local-1', 'mix-a', 'mix-b'],
        current: 'local-1',
      );

      await container.read(sameVibesProvider.notifier).activate(remoteSeed.id);

      verify(
        () => lastFm.getSimilarTracksResult(
          artist: 'ONE OK ROCK',
          track: 'Dystopia',
          limit: any(named: 'limit'),
        ),
      ).called(1);
      verifyNever(
        () => lastFm.getSimilarTracksResult(
          artist: 'Local Artist',
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      );
      final queue = queueOf(container);
      expect(queue.retainedSongIds, <String>[remoteSeed.id]);
      expect(queue.queuedSongs.map((song) => song.id), <String>['gone']);
      final session = container.read(recommendationSessionProvider);
      expect(session.seedId, remoteSeed.id);
      expect(session.stage, 'active');
      expect(session.insertedCount, 1);
    });

    test('starting again from the same song queues its mix again', () async {
      // The previous mix from this seed is still queued behind it; starting
      // over keeps only the seed, so those songs are not duplicates.
      final previousMix = List<Song>.generate(
        5,
        (index) => Song(id: 'sim-$index', title: 'Similar $index'),
      );
      when(
        () => api.getSimilarSongs(
          'local-1',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => previousMix);
      final container = playing(
        queue: <String>['local-1', ...previousMix.map((song) => song.id)],
        current: 'local-1',
      );

      await container.read(sameVibesProvider.notifier).activate('local-1');

      expect(
        queueOf(container).queuedSongs.map((song) => song.id),
        previousMix.map((song) => song.id),
      );
      final session = container.read(recommendationSessionProvider);
      expect(session.stage, 'active');
      expect(session.insertedCount, 5);
    });

    test('a remote seed asks the server about its library copy', () async {
      when(
        () =>
            api.getSong(remoteSeed.id, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => const Song(
          id: 'lib-copy',
          title: 'Dystopia',
          artist: 'ONE OK ROCK',
        ),
      );
      when(
        () => api.getSimilarSongs(
          'lib-copy',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[Song(id: 'sim-copy', title: 'Copy Mix')],
      );
      when(
        () => api.getSimilarSongs(
          'local-1',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[Song(id: 'sim-local', title: 'Unrelated')],
      );
      final container = playing(
        queue: const <String>['local-1', 'mix-a'],
        current: 'local-1',
      );

      await container.read(sameVibesProvider.notifier).activate(remoteSeed.id);

      expect(queueOf(container).retainedSongIds, <String>[remoteSeed.id]);
      expect(queueOf(container).queuedSongs.map((song) => song.id), <String>[
        'sim-copy',
      ]);
      verifyNever(
        () => api.getSimilarSongs(
          'local-1',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    });

    test('activating again while a refill runs inserts for the second seed '
        'and the first never lands in it', () async {
      final firstFetch = Completer<LastFmTrackFetchResult>();
      var lastFmCalls = 0;
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) {
        lastFmCalls++;
        return lastFmCalls == 1
            ? firstFetch.future
            : Future<LastFmTrackFetchResult>.value(
                const LastFmTrackFetchResult(
                  outcome: LastFmFetchOutcome.noResults,
                  tracks: <LastFmTrackRecommendation>[],
                ),
              );
      });
      when(
        () => api.getSimilarSongs(
          'seed-a',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[Song(id: 'a-0', title: 'A')]);
      when(
        () => api.getSimilarSongs(
          'seed-b',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[Song(id: 'b-0', title: 'B')]);
      final container = playing(
        queue: const <String>['seed-a', 'seed-b'],
        current: 'seed-a',
      );
      final notifier = container.read(sameVibesProvider.notifier);

      unawaited(notifier.activate('seed-a'));
      await pumpEventQueue();
      await notifier.activate('seed-b');

      void expectSecondMixActive() {
        final queue = queueOf(container);
        expect(queue.retainedSongIds, <String>['seed-b']);
        expect(queue.queuedSongs.map((song) => song.id), <String>['b-0']);
        final session = container.read(recommendationSessionProvider);
        expect(session.seedId, 'seed-b');
        expect(session.stage, 'active');
        expect(session.insertedCount, 1);
        final state = container.read(sameVibesProvider);
        expect(state.active, isTrue);
        expect(state.error, isNull);
      }

      expectSecondMixActive();
      // The superseded refill fails afterwards; its failure is dropped.
      firstFetch.completeError(StateError('first fetch failed'));
      await pumpEventQueue();
      expectSecondMixActive();
    });

    test('a superseded first refill whose server fallback finishes late '
        "leaves the new mix's queue alone", () async {
      // Without Last.fm the server fallback is the main path.
      final firstFallback = Completer<List<Song>>();
      when(
        () => api.getSimilarSongs(
          'seed-a',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) => firstFallback.future);
      when(
        () => api.getSimilarSongs(
          'seed-b',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => const <Song>[Song(id: 'b-0', title: 'B')]);
      final container = playing(
        queue: const <String>['seed-a', 'seed-b'],
        current: 'seed-a',
      );
      final notifier = container.read(sameVibesProvider.notifier);

      unawaited(notifier.activate('seed-a'));
      await pumpEventQueue();
      await notifier.activate('seed-b');
      firstFallback.complete(const <Song>[Song(id: 'a-0', title: 'A')]);
      await pumpEventQueue();

      final queue = queueOf(container);
      expect(queue.retainedSongIds, <String>['seed-b']);
      expect(queue.queuedSongs.map((song) => song.id), <String>['b-0']);
      final session = container.read(recommendationSessionProvider);
      expect(session.seedId, 'seed-b');
      expect(session.stage, 'active');
      expect(session.insertedCount, 1);
      expect(container.read(sameVibesProvider).active, isTrue);
    });

    test('a playing remote seed mixes from its library copy, never queueing '
        'the copy itself', () async {
      // The main UI case: a remote search result plays and Same Vibes starts
      // from it, so title and artist come from the media item.
      when(
        () =>
            api.getSong(remoteSeed.id, cancelToken: any(named: 'cancelToken')),
      ).thenAnswer(
        (_) async => const Song(
          id: 'lib-copy',
          title: 'Dystopia',
          artist: 'ONE OK ROCK',
        ),
      );
      when(
        () => api.getSimilarSongs(
          'lib-copy',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[
          Song(id: 'lib-copy', title: 'Dystopia (library)'),
          Song(id: 'sim-copy', title: 'Copy Mix'),
        ],
      );
      final container = playing(
        queue: <String>[remoteSeed.id, 'mix-a'],
        current: remoteSeed.id,
        currentTitle: 'Dystopia',
        currentArtist: 'ONE OK ROCK',
      );

      await container.read(sameVibesProvider.notifier).activate(remoteSeed.id);

      verify(
        () => lastFm.getSimilarTracksResult(
          artist: 'ONE OK ROCK',
          track: 'Dystopia',
          limit: any(named: 'limit'),
        ),
      ).called(1);
      expect(queueOf(container).queuedSongs.map((song) => song.id), <String>[
        'sim-copy',
      ]);
      expect(container.read(recommendationSessionProvider).stage, 'active');
    });

    test('a remote seed without a library copy does not borrow the playing '
        "song's server mix", () async {
      when(
        () => api.getSimilarSongs(
          'local-1',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[Song(id: 'sim-local', title: 'Unrelated')],
      );
      final container = playing(
        queue: const <String>['local-1', 'mix-a'],
        current: 'local-1',
      );

      await container.read(sameVibesProvider.notifier).activate(remoteSeed.id);

      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(queueOf(container).queuedSongs, isEmpty);
      expect(
        container.read(sameVibesProvider).error,
        SameVibesError.networkError,
      );
      expect(container.read(recommendationSessionProvider).stage, 'failed');
    });

    test('a playing remote seed without a library copy does not borrow a queue '
        "neighbour's server mix", () async {
      when(
        () => api.getSimilarSongs(
          'local-neighbor',
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const <Song>[Song(id: 'sim-local', title: 'Unrelated')],
      );
      final container = playing(
        queue: <String>[remoteSeed.id, 'local-neighbor'],
        current: remoteSeed.id,
      );

      await container.read(sameVibesProvider.notifier).activate(remoteSeed.id);

      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
      expect(queueOf(container).queuedSongs, isEmpty);
    });
  });

  group('retry exhaustion', () {
    late _MockSubsonicApiClient api;
    late _MockLastFmApiClient lastFm;
    var similarCalls = 0;
    var fakeNow = DateTime(2026, 10, 9, 12);

    setUp(() {
      similarCalls = 0;
      fakeNow = DateTime(2026, 10, 9, 12);
      recommendationNow = () => fakeNow;
      api = _MockSubsonicApiClient();
      lastFm = _MockLastFmApiClient();
      when(
        () => lastFm.getSimilarTracksResult(
          artist: any(named: 'artist'),
          track: any(named: 'track'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer(
        (_) async => const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.noResults,
          tracks: <LastFmTrackRecommendation>[],
        ),
      );
      when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
          .thenAnswer(
            (_) async => const Song(id: 'q', title: 'Seed', artist: 'Artist'),
          );
      // The first (initial) refill succeeds; every later one finds nothing.
      when(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async {
        similarCalls++;
        return similarCalls == 1
            ? List<Song>.generate(
                5,
                (index) => Song(id: 'rec-$index', title: 'Rec $index'),
              )
            : const <Song>[];
      });
    });

    tearDown(() => recommendationNow = DateTime.now);

    test(
      'five failed refills stop the mix until it is started again',
      () async {
        final snapshotState =
            NotifierProvider<_SnapshotController, PlaybackSnapshot>(
              _SnapshotController.new,
            );
        final container = ProviderContainer(
          overrides: [
            playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
            queueProvider.overrideWith(_FakeQueueController.new),
            subsonicApiProvider.overrideWithValue(api),
            lastFmApiClientProvider.overrideWithValue(lastFm),
            integrationPolicyProvider.overrideWithValue(
              const IntegrationPolicy(lastFmVerified: true),
            ),
            currentMediaItemProvider.overrideWith(
              (ref) => Stream<MediaItem?>.value(
                const MediaItem(id: 'seed-a', title: 'Seed', artist: 'Artist'),
              ),
            ),
            downloadedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{}),
            ),
            cachedSongIdsProvider.overrideWithValue(
              const AsyncData(<String>{}),
            ),
            sameVibesAlbumSongCountLookupProvider.overrideWithValue(
              (albumIds) async => const <String, int?>{},
            ),
            sameVibesQueueSongKeyLookupProvider.overrideWithValue(
              (songIds) async => const <String>{},
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(currentMediaItemProvider, (_, _) {});
        final notifier = container.read(sameVibesProvider.notifier);
        void emit(int length) => container
            .read(snapshotState.notifier)
            .emitSnapshot(
              snapshot(
                queueSongIds: List<String>.generate(length, (i) => 'q-$i'),
                currentSongId: 'q-${length - 1}',
                currentIndex: length - 1,
              ),
            );
        // Each step plays the last queued song, so a refill is due, and moves
        // the clock past any backoff.
        Future<void> playToEnd(int length) async {
          fakeNow = fakeNow.add(const Duration(minutes: 5));
          emit(length);
          await pumpEventQueue();
          while (container.read(sameVibesProvider).refilling) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        }

        emit(1);
        await notifier.activate('seed-a');
        expect(similarCalls, 1);

        await playToEnd(6);
        expect(similarCalls, 2);
        expect(
          container.read(recommendationSessionProvider).stage,
          'retryPending',
          reason: 'a failed refill must not overwrite its retry stage',
        );
        for (var length = 7; length <= 9; length++) {
          await playToEnd(length);
        }
        expect(similarCalls, 5);
        expect(
          container.read(recommendationSessionProvider).stage,
          'retryPending',
        );
        await playToEnd(10);
        expect(similarCalls, 6);
        expect(
          container.read(recommendationSessionProvider).stage,
          'retryExhausted',
        );
        expect(container.read(recommendationSessionProvider).retryCount, 5);

        // Later snapshots no longer resume the exhausted refill.
        await playToEnd(11);
        await playToEnd(12);
        expect(similarCalls, 6);
        expect(
          container.read(recommendationSessionProvider).stage,
          'retryExhausted',
        );
        expect(container.read(sameVibesProvider).active, isTrue);

        // Starting the mix again re-arms it.
        await notifier.activate('seed-a');
        expect(similarCalls, 7);
      },
    );
  });
}
