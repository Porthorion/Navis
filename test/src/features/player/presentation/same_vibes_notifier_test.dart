import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

class _SnapshotController extends Notifier<PlaybackSnapshot> {
  @override
  PlaybackSnapshot build() => const PlaybackSnapshot.idle();

  void setSnapshot(PlaybackSnapshot snapshot) {
    state = snapshot;
  }
}

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient {}

class _MockLastFmApiClient extends Mock implements LastFmApiClient {}

class _FakeQueueController extends QueueController {
  final List<Song> queuedSongs = <Song>[];

  @override
  List<String> build() => const <String>[];

  @override
  Future<void> addWithSongs(
    List<Song> songs, {
    bool expandMatchFlows = true,
  }) async {
    queuedSongs.addAll(songs);
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
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
            Song(
              id: '$artist-$title',
              title: title,
              artist: artist,
            ),
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

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
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
          .setSnapshot(
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
      expect(queued.queuedSongs, hasLength(4));
      expect(state.active, isTrue);
      expect(state.pendingSnackbar, '4');
      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

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
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
          .setSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final queued =
          container.read(queueProvider.notifier) as _FakeQueueController;
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
    'does not fallback to Subsonic when Last.fm has transient network failure',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
      ).thenAnswer((_) async => const <Song>[]);

      final container = ProviderContainer(
        overrides: [
          playerStateProvider.overrideWith((ref) => ref.watch(snapshotState)),
          queueProvider.overrideWith(_FakeQueueController.new),
          subsonicApiProvider.overrideWithValue(api),
          lastFmApiClientProvider.overrideWithValue(lastFm),
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
          .setSnapshot(
            snapshot(
              queueSongIds: const <String>['seed', 'a', 'b'],
              currentSongId: 'seed',
              currentIndex: 0,
            ),
          );

      await container.read(sameVibesProvider.notifier).activate('seed');

      final state = container.read(sameVibesProvider);
      expect(state.active, isTrue);
      expect(state.refilling, isFalse);
      expect(state.error, isNull);
      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

  test(
    'skips Subsonic fallback for external seed ids when no server-like seed is available',
    () async {
      final snapshotState =
          NotifierProvider<_SnapshotController, PlaybackSnapshot>(
            _SnapshotController.new,
          );

      final api = _MockSubsonicApiClient();
      final lastFm = _MockLastFmApiClient();
      when(
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'ext-seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
          .setSnapshot(
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
      expect(state.active, isTrue);
      expect(state.refilling, isFalse);
      verifyNever(
        () => api.getSimilarSongs(
          any(),
          count: any(named: 'count'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    },
  );

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
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
          .setSnapshot(
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
    when(
      () => api.getSong(
        any(),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => const Song(
        id: 'seed',
        title: 'Seed Song',
        artist: 'Seed Artist',
      ),
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
        .setSnapshot(
          snapshot(
            queueSongIds: const <String>['seed', 'a', 'b', 'c'],
            currentSongId: 'seed',
            currentIndex: 0,
          ),
        );

    await container.read(sameVibesProvider.notifier).activate('seed');

    container
        .read(snapshotState.notifier)
        .setSnapshot(
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
        () => api.getSong(
          any(),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer(
        (_) async => const Song(
          id: 'seed',
          title: 'Seed Song',
          artist: 'Seed Artist',
        ),
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
          .setSnapshot(
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
}
