import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/recommendation_test_harness.dart';

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient {}

class _MockLastFmApiClient extends Mock implements LastFmApiClient {}

class _MockDeezerApiClient extends Mock implements DeezerApiClient {}

class _MockResolver extends Mock implements DeezerArtistResolver {}

class _ModeController extends Notifier<PreferredMixMode> {
  @override
  PreferredMixMode build() => PreferredMixMode.sameVibesDeezer;

  void set(PreferredMixMode mode) => state = mode;
}

final _modeProvider = NotifierProvider<_ModeController, PreferredMixMode>(
  _ModeController.new,
);

DeezerTrack _radioTrack(String letter, {String? artist}) => DeezerTrack(
  id: letter.codeUnitAt(0),
  title: 'Song$letter',
  artist: DeezerArtist(id: 9, name: artist ?? 'Artist$letter'),
);

const _letters = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L'];

class _Rig {
  _Rig({PreferredMixMode mode = PreferredMixMode.sameVibesDeezer}) {
    when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (_) async => const Song(
            id: 'seed',
            title: 'Seed Song',
            artist: 'Seed Artist',
            artistId: 'ar-1',
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
      final parts = (invocation.namedArguments[#query] as String).split(' ');
      return SearchResult3(
        songs: <Song>[
          Song(
            id: '${parts.first}-${parts.last}',
            title: parts.last,
            artist: parts.first,
          ),
        ],
      );
    });
    serverSimilar = const <Song>[];
    when(
      () => api.getSimilarSongs(
        any(),
        count: any(named: 'count'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => serverSimilar);
    // A valid Last.fm key that would answer 10 songs, or a rejected key.
    when(
      () => lastFm.getSimilarTracksResult(
        artist: any(named: 'artist'),
        track: any(named: 'track'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => lastFmResult);
    when(
      () => resolver.resolve(
        artistId: any(named: 'artistId'),
        name: any(named: 'name'),
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer((_) async => 27);
    radio = () async => [for (final l in _letters.take(10)) _radioTrack(l)];
    when(
      () => deezer.getArtistRadio(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer((_) => radio());
    this.mode = mode;
  }

  final api = _MockSubsonicApiClient();
  final lastFm = _MockLastFmApiClient();
  final deezer = _MockDeezerApiClient();
  final resolver = _MockResolver();
  late Future<List<DeezerTrack>> Function() radio;
  late List<Song> serverSimilar;
  late PreferredMixMode mode;
  var lastFmResult = LastFmTrackFetchResult(
    outcome: LastFmFetchOutcome.success,
    tracks: [
      for (final l in _letters.take(10))
        LastFmTrackRecommendation(
          artist: 'Artist$l',
          title: 'Song$l',
          match: 1,
        ),
    ],
  );
  var now = DateTime(2026, 11, 18, 12);

  late final ProviderContainer container = createRecommendationContainer(
    lastFmMode: false,
    overrides: [
      _modeProvider.overrideWith(_ModeController.new),
      preferredMixModeProvider.overrideWith((ref) => ref.watch(_modeProvider)),
      queueProvider.overrideWith(RecordingRecommendationQueue.new),
      sameVibesProvider.overrideWith(() => SameVibesNotifier(now: () => now)),
      subsonicApiProvider.overrideWithValue(api),
      lastFmApiClientProvider.overrideWithValue(lastFm),
      deezerApiClientProvider.overrideWithValue(deezer),
      deezerArtistResolverProvider.overrideWithValue(resolver),
      integrationPolicyProvider.overrideWithValue(
        const IntegrationPolicy(lastFmVerified: true),
      ),
      currentMediaItemProvider.overrideWith(
        (ref) => Stream<MediaItem?>.value(
          const MediaItem(
            id: 'seed',
            title: 'Seed Song',
            artist: 'Seed Artist',
            extras: {'artistId': 'ar-1'},
          ),
        ),
      ),
      downloadedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
      cachedSongIdsProvider.overrideWithValue(const AsyncData(<String>{})),
      sameVibesAlbumSongCountLookupProvider.overrideWithValue(
        (albumIds) async => const <String, int?>{},
      ),
      sameVibesQueueSongKeyLookupProvider.overrideWithValue(
        (songIds) async => const <String>{},
      ),
    ],
  );

  RecordingRecommendationQueue get queue =>
      container.read(queueProvider.notifier) as RecordingRecommendationQueue;
  SameVibesNotifier get notifier => container.read(sameVibesProvider.notifier);
  SameVibesState get state => container.read(sameVibesProvider);

  void emit(int length, [int tick = 0]) => container
      .read(recommendationSnapshotProvider.notifier)
      .emitSnapshot(
        recommendationSnapshot(
          queueSongIds: length == 1
              ? const ['seed']
              : ['seed', for (var i = 1; i < length; i++) 'q-$i'],
          currentSongId: length == 1 ? 'seed' : 'q-${length - 1}',
          currentIndex: length - 1,
        ).copyWith(position: Duration(seconds: tick)),
      );

  Future<void> start() async {
    container.read(_modeProvider.notifier).set(mode);
    emit(1);
    await notifier.activate('seed');
  }

  /// Plays the end of a longer queue so a non-initial refill is due.
  Future<void> refill() async {
    now = now.add(const Duration(minutes: 5));
    emit(6, 1);
    await pumpEventQueue();
    while (state.refilling) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void verifyLastFmNeverCalled() => verifyNever(
    () => lastFm.getSimilarTracksResult(
      artist: any(named: 'artist'),
      track: any(named: 'track'),
      limit: any(named: 'limit'),
    ),
  );
}

List<String> _ids(Iterable<Song> songs) => [for (final s in songs) s.id];

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
  });

  test('Deezer mode queues the artist radio and never calls Last.fm', () async {
    final rig = _Rig();
    await rig.start();

    expect(_ids(rig.queue.queuedSongs), hasLength(10));
    expect(rig.queue.queuedSongs.first.id, 'ArtistA-SongA');
    rig.verifyLastFmNeverCalled();
    expect(
      rig.container.read(sameVibesProvider.notifier).lastRefill?.mixSource,
      'deezer',
    );
    verify(
      () => rig.resolver.resolve(
        artistId: 'ar-1',
        name: 'Seed Artist',
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: false,
        retryQuota: any(named: 'retryQuota'),
      ),
    ).called(1);
  });

  test('Deezer mode with an empty radio never reads the Last.fm answer, '
      'so a rejected key is no error', () async {
    final rig = _Rig()
      ..radio = (() async => <DeezerTrack>[])
      ..lastFmResult = const LastFmTrackFetchResult(
        outcome: LastFmFetchOutcome.apiError,
        tracks: <LastFmTrackRecommendation>[],
        apiErrorCode: 10,
      );
    await rig.start();

    expect(rig.state.error, SameVibesError.networkError);
    rig.verifyLastFmNeverCalled();

    // A later refill parks the seed instead of retrying.
    final refill = _Rig();
    await refill.start();
    refill.radio = () async => <DeezerTrack>[];
    await refill.refill();
    expect(refill.notifier.lastRefill?.parkedSeedId, isNotNull);
    expect(
      refill.container.read(recommendationSessionProvider).stage,
      isNot('retryPending'),
    );
  });

  test('a Deezer quota refusal skips Deezer, asked without retries', () async {
    final rig = _Rig()
      ..radio = (() async => throw const DeezerApiException(code: 4));
    rig.serverSimilar = [
      for (final l in _letters.take(4)) Song(id: 'srv-$l', title: 'S$l'),
    ];
    await rig.start();

    expect(rig.notifier.lastRefill?.mixSource, 'server');
    verify(
      () => rig.resolver.resolve(
        artistId: any(named: 'artistId'),
        name: any(named: 'name'),
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: false,
      ),
    ).called(1);
    verify(
      () => rig.deezer.getArtistRadio(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: false,
      ),
    ).called(1);
  });

  test(
    'no artist match falls to the server and labels the mix server',
    () async {
      final rig = _Rig();
      when(
        () => rig.resolver.resolve(
          artistId: any(named: 'artistId'),
          name: any(named: 'name'),
          readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      ).thenAnswer((_) async => null);
      rig.serverSimilar = [
        for (final l in _letters.take(4)) Song(id: 'srv-$l', title: 'S$l'),
      ];
      await rig.start();

      expect(_ids(rig.queue.queuedSongs), hasLength(4));
      expect(rig.notifier.lastRefill?.mixSource, 'server');
      verifyNever(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
    },
  );

  test('a quota answer skips Deezer for this refill: server fills, no retry, '
      'no error', () async {
    final rig = _Rig();
    rig.radio = () async => throw const DeezerApiException(code: 4);
    rig.serverSimilar = [
      for (final l in _letters.take(5)) Song(id: 'srv-$l', title: 'S$l'),
    ];
    await rig.start();

    expect(_ids(rig.queue.queuedSongs), hasLength(5));
    expect(rig.state.error, isNull);
    expect(rig.notifier.lastRefill?.fallbackReason, 'deezer_skipped');
    expect(
      rig.container.read(recommendationSessionProvider).stage,
      isNot('retryPending'),
    );
  });

  test('a quota answer with nothing from the server parks a refill without '
      'a retry', () async {
    final rig = _Rig();
    await rig.start();
    rig.radio = () async => throw const DeezerApiException(code: 4);
    await rig.refill();

    expect(rig.notifier.lastRefill?.parkedSeedId, isNotNull);
    expect(
      rig.container.read(recommendationSessionProvider).stage,
      isNot('retryPending'),
    );
  });

  test('a Deezer leg that hangs is cancelled after 6 seconds and the server '
      'fills', () {
    fakeAsync((async) {
      final rig = _Rig();
      CancelToken? seen;
      when(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      ).thenAnswer((invocation) {
        seen = invocation.namedArguments[#cancelToken] as CancelToken?;
        return Completer<List<DeezerTrack>>().future;
      });
      rig.serverSimilar = [
        for (final l in _letters.take(5)) Song(id: 'srv-$l', title: 'S$l'),
      ];
      var done = false;
      unawaited(rig.start().then((_) => done = true));
      async.elapse(const Duration(seconds: 5));
      expect(done, isFalse, reason: 'still waiting inside the 6 s budget');
      expect(seen?.isCancelled, isFalse);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();

      expect(seen?.isCancelled, isTrue);
      expect(done, isTrue);
      expect(_ids(rig.queue.queuedSongs), hasLength(5));
      expect(rig.notifier.lastRefill?.fallbackReason, 'deezer_skipped');
      expect(rig.state.error, isNull);
    });
  });

  test(
    'a Deezer transport error schedules a transient retry on a refill',
    () async {
      final rig = _Rig();
      await rig.start();
      rig.radio = () async => throw DioException(
        requestOptions: RequestOptions(path: 'artist/27/radio'),
        type: DioExceptionType.connectionError,
      );
      await rig.refill();

      expect(
        rig.container.read(recommendationSessionProvider).stage,
        'retryPending',
      );
      rig.notifier.deactivate();
    },
  );

  test(
    'radio repeats of queued songs, the seed and itself are queued once',
    () async {
      final rig = _Rig();
      rig.radio = () async => [
        _radioTrack('A'),
        _radioTrack('A'),
        _radioTrack('B'),
        _radioTrack('S', artist: 'Seed Artist').copyWithTitle('Seed Song'),
        _radioTrack('C'),
      ];
      await rig.start();

      expect(_ids(rig.queue.queuedSongs), <String>[
        'ArtistA-SongA',
        'ArtistB-SongB',
        'ArtistC-SongC',
      ]);
    },
  );

  test('a refill and the anchor fetch always run in the background', () async {
    final rig = _Rig();
    await rig.start();
    await rig.refill();

    final calls = verify(
      () => rig.resolver.resolve(
        artistId: any(named: 'artistId'),
        name: any(named: 'name'),
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: captureAny(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).captured;
    expect(calls.first, isFalse, reason: 'the first tap is foreground');
    expect(calls.last, isTrue, reason: 'later refills yield to the user');
  });

  test(
    'Last.fm mode with a rejected user key reports invalidKey as today',
    () async {
      final rig = _Rig(mode: PreferredMixMode.sameVibesLastFm)
        ..radio = (() async => <DeezerTrack>[])
        ..lastFmResult = const LastFmTrackFetchResult(
          outcome: LastFmFetchOutcome.apiError,
          tracks: <LastFmTrackRecommendation>[],
          apiErrorCode: 10,
        );
      await rig.start();

      expect(rig.state.error, SameVibesError.invalidKey);
    },
  );

  test('Last.fm mode queues its songs and labels the mix lastFm', () async {
    final rig = _Rig(mode: PreferredMixMode.sameVibesLastFm);
    await rig.start();

    expect(_ids(rig.queue.queuedSongs), hasLength(10));
    expect(rig.notifier.lastRefill?.mixSource, 'lastFm');
    verifyNever(
      () => rig.resolver.resolve(
        artistId: any(named: 'artistId'),
        name: any(named: 'name'),
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    );
  });

  test('switching to Server Mix mid-mix makes the next refill call nothing '
      'external', () async {
    final rig = _Rig();
    await rig.start();
    clearInteractions(rig.lastFm);
    clearInteractions(rig.deezer);
    rig.container
        .read(_modeProvider.notifier)
        .set(PreferredMixMode.legacyInstantMix);
    await rig.refill();

    rig.verifyLastFmNeverCalled();
    verifyNever(
      () => rig.deezer.getArtistRadio(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    );
    expect(rig.notifier.lastRefill?.lastFmOutcome, 'notConfigured');
  });

  test('switching source mid-mix takes effect at the next refill', () async {
    final rig = _Rig();
    await rig.start();
    rig.container
        .read(_modeProvider.notifier)
        .set(PreferredMixMode.sameVibesLastFm);
    await rig.refill();

    expect(rig.notifier.lastRefill?.mixSource, 'lastFm');
  });

  test('an artist radio track with a Deezer artist that has no name is '
      'skipped', () async {
    final rig = _Rig();
    rig.radio = () async => [
      const DeezerTrack(
        id: 1,
        title: 'Nameless',
        artist: DeezerArtist(id: 0, name: ''),
      ),
      _radioTrack('A'),
    ];
    await rig.start();

    expect(_ids(rig.queue.queuedSongs), ['ArtistA-SongA']);
  });
}

extension on DeezerTrack {
  DeezerTrack copyWithTitle(String title) =>
      DeezerTrack(id: id, title: title, artist: artist);
}
