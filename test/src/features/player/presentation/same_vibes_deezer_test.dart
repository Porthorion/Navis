import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/domain/same_vibes_state.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/features/player/presentation/recommendation_session_coordinator.dart';
import 'package:navis/src/features/player/presentation/same_vibes_notifier.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/recommendation_test_harness.dart';
import '../../../../helpers/test_database.dart';

class _MockSubsonicApiClient extends Mock implements SubsonicApiClient {}

class _MockLastFmApiClient extends Mock implements LastFmApiClient {}

class _MockDeezerApiClient extends Mock implements DeezerApiClient {}

class _MockResolver extends Mock implements DeezerArtistResolver {}

/// In-memory stand-in for the disk cache (no file I/O, so fake_async works).
class _MemoryCache extends IntegrationJsonCache {
  new();

  final Map<String, Object?> _entries = <String, Object?>{};

  @override
  Future<IntegrationCacheHit?> read(String namespace, String key) async {
    final entry = '$namespace/$key';
    return _entries.containsKey(entry)
        ? IntegrationCacheHit(value: _entries[entry], storedAt: DateTime.now())
        : null;
  }

  @override
  Future<void> write(
    String namespace,
    String key,
    Object? value, {
    required Duration ttl,
  }) async {
    _entries['$namespace/$key'] = value;
  }
}

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
  _Rig({
    PreferredMixMode mode = PreferredMixMode.sameVibesDeezer,
    this.seedTitle = 'Seed Song',
    this.seedArtist = 'Seed Artist',
    this.seedArtistId = 'ar-1',
  }) {
    addTearDown(_database.close);
    when(() => api.getSong(any(), cancelToken: any(named: 'cancelToken')))
        .thenAnswer(
          (invocation) async =>
              songById[invocation.positionalArguments.first as String] ??
              Song(
                id: 'seed',
                title: seedTitle,
                artist: seedArtist,
                artistId: seedArtistId,
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
    ).thenAnswer((_) async => seedDeezerId);
    radio = () async => [for (final l in _letters.take(10)) _radioTrack(l)];
    when(
      () => deezer.getArtistRadio(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer(
      (invocation) => invocation.positionalArguments.first == seedDeezerId
          ? radio()
          : relatedRadio(invocation.positionalArguments.first as int),
    );
    when(
      () => deezer.getRelatedArtists(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer((_) async => relatedArtists);
    when(
      () => deezer.getArtistTopTracks(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer(
      (invocation) => relatedTop(invocation.positionalArguments.first as int),
    );
    when(
      () => deezer.getTrack(
        any(),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).thenAnswer(
      (invocation) async => trackFeatures[invocation.positionalArguments.first],
    );
    when(
      () => deezer.searchTracks(
        any(),
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => searchHits);
    this.mode = mode;
  }

  final String seedTitle;
  final String seedArtist;
  final String seedArtistId;

  /// The Deezer artist the resolver answers for the seed.
  var seedDeezerId = 27;
  var relatedArtists = const <DeezerArtist>[];
  Future<List<DeezerTrack>> Function(int artistId) relatedRadio = (_) async =>
      const <DeezerTrack>[];
  Future<List<DeezerTrack>> Function(int artistId) relatedTop = (_) async =>
      const <DeezerTrack>[];
  final trackFeatures = <int, DeezerTrack>{};
  var searchHits = const <DeezerTrack>[];
  final api = _MockSubsonicApiClient();

  /// Songs the playing queue can hold besides the seed, by id.
  final songById = <String, Song>{};
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

  final _database = createTestDatabase();
  final positions = StreamController<Duration>.broadcast();

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
      deezerCatalogProvider.overrideWithValue(
        DeezerCatalog(client: deezer, cache: _MemoryCache()),
      ),
      navisDatabaseProvider.overrideWithValue(_database),
      integrationPolicyProvider.overrideWithValue(
        const IntegrationPolicy(lastFmVerified: true),
      ),
      currentMediaItemProvider.overrideWith(
        (ref) => Stream<MediaItem?>.value(
          MediaItem(
            id: 'seed',
            title: seedTitle,
            artist: seedArtist,
            extras: {'artistId': seedArtistId},
          ),
        ),
      ),
      playbackPositionProvider.overrideWith((ref) => positions.stream),
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

  /// Makes [id] the current song of a queue holding the mix, reports
  /// [position] into it and lets the notifier see both.
  Future<void> play(String id, {Duration? position, int tick = 0}) async {
    container
        .read(recommendationSnapshotProvider.notifier)
        .emitSnapshot(
          recommendationSnapshot(
            queueSongIds: ['seed', ..._ids(queue.queuedSongs), 'q-9'],
            currentSongId: id,
            currentIndex: 0,
          ).copyWith(position: Duration(milliseconds: tick)),
        );
    await pumpEventQueue();
    if (position != null) {
      positions.add(position);
      await pumpEventQueue();
    }
  }

  /// Lets the unawaited background top-up run to its end.
  Future<void> settle() => pumpEventQueue(times: 300);

  Future<void> start() async {
    // The mix is listened to in the app; an unlistened notifier is paused.
    container.listen(sameVibesProvider, (_, _) {});
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

  test('a refill on a song by another artist still asks Deezer for the '
      'anchor artist (#743)', () async {
    final rig = _Rig();
    rig.songById['q-5'] = Song(
      id: 'q-5',
      title: 'Elsewhere',
      artist: 'Other Artist',
      artistId: 'ar-2',
    );
    await rig.start();
    rig.radio = () async => [
      for (final l in ['M', 'N', 'O']) _radioTrack(l),
    ];
    await rig.refill();

    final asked = verify(
      () => rig.resolver.resolve(
        artistId: captureAny(named: 'artistId'),
        name: captureAny(named: 'name'),
        readLibraryAlbumTitles: any(named: 'readLibraryAlbumTitles'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).captured;
    // The pool resolves the anchor artist once and reuses the id.
    expect(asked, hasLength(2));
    expect(asked.toSet(), {'ar-1', 'Seed Artist'});
    verify(
      () => rig.deezer.getArtistRadio(
        27,
        limit: any(named: 'limit'),
        cancelToken: any(named: 'cancelToken'),
        background: any(named: 'background'),
        retryQuota: any(named: 'retryQuota'),
      ),
    ).called(2);
    final record = rig.notifier.lastRefill!;
    expect(record.seedId, 'seed');
    expect(record.triggerId, 'q-5');
    expect(rig.state.seedSongId, 'seed');
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
      () => rig.deezer.getArtistRadio(
        any(),
        limit: any(named: 'limit'),
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
    // Songs the first batch queued are not queued again.
    rig.lastFmResult = const LastFmTrackFetchResult(
      outcome: LastFmFetchOutcome.success,
      tracks: [
        LastFmTrackRecommendation(artist: 'ArtistK', title: 'SongK', match: 1),
      ],
    );
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
  group('variety (#721)', () {
    Song srv(String id, String artist, String title) =>
        Song(id: id, title: title, artist: artist);

    List<String> artistsOf(Iterable<Song> songs) => [
      for (final s in songs) s.artist ?? '',
    ];

    test('asks Deezer for 40 radio songs', () async {
      final rig = _Rig();
      await rig.start();

      verify(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: 40,
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      ).called(1);
    });

    test('a refill after the batch played and left the queue queues none of '
        'its songs again', () async {
      final rig = _Rig();
      await rig.start();
      expect(_ids(rig.queue.queuedSongs), hasLength(10));

      // The new queue holds none of the first batch: it was played and removed.
      await rig.refill();

      expect(rig.queue.appendedSongBatches, hasLength(1));
      expect(rig.notifier.lastRefill?.parkedSeedId, isNotNull);
    });

    test('the server fill never repeats a played song or another version of '
        'it', () async {
      final rig = _Rig()..radio = (() async => <DeezerTrack>[]);
      rig.serverSimilar = [srv('s1', 'Ann', 'Song'), srv('s2', 'Bob', 'Other')];
      await rig.start();
      expect(_ids(rig.queue.queuedSongs), ['s1', 's2']);

      rig.serverSimilar = [
        srv('s1', 'Ann', 'Song'),
        srv('s3', 'Ann', 'Song (Live)'),
        srv('s4', 'Bob', 'Other - Sped Up'),
        srv('s5', 'Cyd', 'Fresh'),
      ];
      await rig.refill();

      expect(_ids(rig.queue.queuedSongs), ['s1', 's2', 's5']);
    });

    test('Song, Song (Live) and Song - Sped Up give one entry', () async {
      final rig = _Rig()..radio = (() async => <DeezerTrack>[]);
      rig.serverSimilar = [
        srv('s1', 'Ann', 'Song (Live)'),
        srv('s2', 'Ann', 'Song'),
        srv('s3', 'Ann', 'Song - Sped Up'),
      ];
      await rig.start();

      expect(_ids(rig.queue.queuedSongs), ['s2']);
    });

    test('a sped-up seed keeps sped-up versions', () async {
      final rig = _Rig(seedTitle: 'Seed Song (Sped Up)')
        ..radio = (() async => <DeezerTrack>[]);
      rig.serverSimilar = [
        srv('s1', 'Ann', 'Song - Sped Up'),
        srv('s2', 'Bob', 'Other (Nightcore)'),
      ];
      await rig.start();

      expect(_ids(rig.queue.queuedSongs), ['s1', 's2']);
    });

    test('server fill: two per artist and no back-to-back when others '
        'exist', () async {
      final rig = _Rig()..radio = (() async => <DeezerTrack>[]);
      rig.serverSimilar = [
        for (var i = 0; i < 6; i++) srv('a$i', 'Ann', 'A$i'),
        for (var i = 0; i < 3; i++) srv('b$i', 'Bob', 'B$i'),
        for (var i = 0; i < 3; i++) srv('c$i', 'Cyd', 'C$i'),
      ];
      await rig.start();

      final artists = artistsOf(rig.queue.queuedSongs);
      expect(artists, hasLength(10));
      for (var i = 1; i < artists.length; i++) {
        expect(artists[i], isNot(artists[i - 1]));
      }
      // Bob and Cyd are used up; Ann takes the rest (cap relaxed to 4).
      expect(artists.where((a) => a == 'Bob'), hasLength(3));
      expect(artists.where((a) => a == 'Cyd'), hasLength(3));
    });

    test('a library of only the seed artist still fills the batch', () async {
      final rig = _Rig(seedArtist: 'Various Artists')
        ..radio = (() async => <DeezerTrack>[]);
      rig.serverSimilar = [
        for (var i = 0; i < 12; i++) srv('v$i', 'Various Artists', 'V$i'),
      ];
      await rig.start();

      expect(_ids(rig.queue.queuedSongs), hasLength(10));
    });

    test('candidates are filtered before search3, so searches stay '
        'bounded', () async {
      final rig = _Rig();
      rig.radio = () async => [
        // Only three of the six Dup songs may be searched.
        for (final l in ['A', 'B', 'C', 'D', 'E', 'F'])
          _radioTrack(l, artist: 'Dup'),
        // Junk versions are never searched.
        _radioTrack('G').copyWithTitle('SongG (Sped Up)'),
        _radioTrack('H').copyWithTitle('SongH - Nightcore'),
        _radioTrack('I'),
        _radioTrack('J'),
      ];
      await rig.start();

      final queries = verify(
        () => rig.api.search3(
          query: captureAny(named: 'query'),
          artistCount: any(named: 'artistCount'),
          albumCount: any(named: 'albumCount'),
          songCount: any(named: 'songCount'),
          artistOffset: any(named: 'artistOffset'),
          albumOffset: any(named: 'albumOffset'),
          songOffset: any(named: 'songOffset'),
        ),
      ).captured.cast<String>();
      expect(queries.where((q) => q.startsWith('Dup ')), hasLength(3));
      expect(queries.where((q) => q.contains('Sped')), isEmpty);
      expect(queries.where((q) => q.contains('Nightcore')), isEmpty);
      expect(_ids(rig.queue.queuedSongs), hasLength(5));
    });
  });

  group('anchored pool (#743)', () {
    DeezerTrack tk(int id, String artist, String title, {int artistId = 9}) =>
        DeezerTrack(
          id: id,
          title: title,
          artist: DeezerArtist(id: artistId, name: artist),
        );
    final related6 = [
      for (var i = 0; i < 6; i++)
        DeezerArtist(id: 31 + i, name: 'Rel${31 + i}'),
    ];
    Future<List<DeezerTrack>> relatedList(int id) async => [
      tk(id * 10, 'Rel$id', 'Hit$id', artistId: id),
    ];
    DioException transport() => DioException(
      requestOptions: RequestOptions(path: 'x'),
      type: DioExceptionType.connectionError,
    );
    List<DeezerTrack> freshRadio() => [
      for (var i = 0; i < 6; i++) tk(500 + i, 'New$i', 'Fresh$i'),
    ];
    void verifyNoDeezerCalls(_Rig rig) {
      verifyNever(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.getArtistTopTracks(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.getRelatedArtists(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.getTrack(
          any(),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.searchTracks(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
        ),
      );
    }

    test('the first refill queues in ranked order, not Deezer order', () async {
      final rig = _Rig()
        ..relatedArtists = [const DeezerArtist(id: 31, name: 'Rel')]
        ..relatedRadio = ((_) async => [tk(2, 'Cee', 'Shared')]);
      rig.radio = () async => [
        tk(1, 'Zed', 'Outsider'),
        tk(2, 'Cee', 'Shared'),
        tk(3, 'Kin', 'Home', artistId: 27),
      ];
      await rig.start();

      // The seed artist's song and the one two lists agree on come ahead of
      // the radio's first outsider.
      expect(_ids(rig.queue.queuedSongs), [
        'Cee-Shared',
        'Kin-Home',
        'Zed-Outsider',
      ]);
    });

    for (final n in const [3, 9, 11, 13]) {
      test('golden: seed $n ships the measured first batch', () {
        final fx = jsonDecode(
          File('test/fixtures/same_vibes_rec_v4/seed_$n.json')
              .readAsStringSync(),
        ) as Map<String, dynamic>;
        List<DeezerTrack> tracks(Object? raw) => [
          for (final x in raw! as List)
            DeezerTrack.fromJson(Map<String, dynamic>.from(x as Map)),
        ];
        final seed = fx['seed'] as Map<String, dynamic>;
        final relatedIds = List<int>.from(fx['relatedIds'] as List);
        final lists = fx['related'] as List;
        // The first `shippingN` lists in fetch order arrive in time; the
        // rest never arrive before the 2.5 s deadline.
        const order = [
          (false, 0),
          (false, 1),
          (true, 0),
          (false, 2),
          (false, 3),
          (true, 1),
          (false, 4),
          (false, 5),
          (true, 2),
          (true, 3),
          (true, 4),
          (true, 5),
        ];
        final shipping = order.take(fx['shippingN'] as int).toSet();
        final all = <DeezerTrack>[
          ...tracks(fx['seedRadio']),
          for (final l in lists) ...[
            ...tracks((l as Map)['radio']),
            ...tracks(l['top']),
          ],
        ];
        final byQuery = <String, Song>{
          for (final t in all)
            '${t.artist.name} ${t.title}'.trim().toLowerCase(): Song(
              id: '${t.artist.name}|${t.title}',
              title: t.title,
              artist: t.artist.name,
            ),
        };

        fakeAsync((async) {
          final rig = _Rig(
            seedTitle: seed['title'] as String,
            seedArtist: seed['artist'] as String,
          )..seedDeezerId = seed['seedArtistId'] as int;
          rig.relatedArtists = [
            for (final id in relatedIds) DeezerArtist(id: id, name: 'R$id'),
          ];
          rig.radio = () async => tracks(fx['seedRadio']);
          rig.relatedRadio = (id) async {
            final rank = relatedIds.indexOf(id);
            return shipping.contains((false, rank))
                ? tracks((lists[rank] as Map)['radio'])
                : Completer<List<DeezerTrack>>().future;
          };
          rig.relatedTop = (id) {
            final rank = relatedIds.indexOf(id);
            return shipping.contains((true, rank))
                ? Future.value(tracks((lists[rank] as Map)['top']))
                : Completer<List<DeezerTrack>>().future;
          };
          when(
            () => rig.api.search3(
              query: any(named: 'query'),
              artistCount: any(named: 'artistCount'),
              albumCount: any(named: 'albumCount'),
              songCount: any(named: 'songCount'),
              artistOffset: any(named: 'artistOffset'),
              albumOffset: any(named: 'albumOffset'),
              songOffset: any(named: 'songOffset'),
            ),
          ).thenAnswer((invocation) async {
            final hit =
                byQuery[(invocation.namedArguments[#query] as String)
                    .trim()
                    .toLowerCase()];
            return SearchResult3(songs: [?hit]);
          });
          unawaited(rig.start());
          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();

          expect([
            for (final s in rig.queue.queuedSongs)
              {'artist': s.artist, 'title': s.title},
          ], fx['expectedFirstBatch']);
          expect(rig.notifier.lastRefill?.deezer?['deadlineHit'], isTrue);
          expect(
            rig.notifier.lastRefill?.deezer?['listsUsed'],
            1 + (fx['shippingN'] as int),
          );
        });
      });
    }

    test('a refill after a partial first batch repairs the pool and ranks '
        'with features', () async {
      final rig = _Rig()
        ..relatedArtists = related6
        ..relatedRadio = relatedList
        ..searchHits = [tk(700, 'Seed Artist', 'Seed Song', artistId: 27)];
      final seenTop = <int>{};
      rig.relatedTop = (id) async {
        if (seenTop.add(id)) throw transport();
        return [tk(id * 10 + 1, 'Rel$id', 'Top$id', artistId: id)];
      };
      for (final id in [700, for (var i = 0; i < 10; i++) 65 + i]) {
        rig.trackFeatures[id] = DeezerTrack(
          id: id,
          title: 'f',
          artist: const DeezerArtist(id: 1, name: 'a'),
          bpm: 100,
        );
      }
      await rig.start();
      // Every top five failed once: seed radio + 6 radios arrived.
      expect(rig.notifier.lastRefill?.deezer?['listsUsed'], 7);

      rig.radio = () async => freshRadio();
      await rig.refill();
      final deezerRecord = rig.notifier.lastRefill!.deezer!;
      expect(deezerRecord['listsUsed'], 13);
      expect(deezerRecord['featuresUsed'], greaterThan(1));
      verify(
        () => rig.deezer.getTrack(
          65,
          cancelToken: any(named: 'cancelToken'),
          background: true,
          retryQuota: false,
        ),
      ).called(1);
    });

    test('a skipped first batch is repaired by the top-up for the next '
        'refill', () async {
      final rig = _Rig()
        ..relatedArtists = related6
        ..relatedRadio = relatedList
        ..relatedTop = ((id) async => [tk(id * 10 + 1, 'Rel$id', 'Top$id')]);
      rig.serverSimilar = [
        for (final l in _letters.take(3)) Song(id: 'srv-$l', title: 'S$l'),
      ];
      var first = true;
      rig.radio = () async {
        if (first) {
          first = false;
          throw const DeezerApiException(code: 4);
        }
        return freshRadio();
      };
      await rig.start();
      expect(rig.notifier.lastRefill?.mixSource, 'server');
      expect(rig.notifier.lastRefill?.deezer?['skipped'], isTrue);

      await rig.settle();
      await rig.refill();
      final record = rig.notifier.lastRefill!;
      expect(record.mixSource, 'deezer');
      expect(record.deezer?['skipped'], isFalse);
      expect(record.deezer?['listsUsed'], 13);
    });

    test('the resolver gets the library album reader for a library seed '
        'and none for an ext- artist', () async {
      Future<List<Object?>> readers(String artistId) async {
        final rig = _Rig(seedArtistId: artistId);
        await rig.start();
        return verify(
          () => rig.resolver.resolve(
            artistId: any(named: 'artistId'),
            name: any(named: 'name'),
            readLibraryAlbumTitles: captureAny(named: 'readLibraryAlbumTitles'),
            cancelToken: any(named: 'cancelToken'),
            background: any(named: 'background'),
            retryQuota: any(named: 'retryQuota'),
          ),
        ).captured;
      }

      expect((await readers('ar-1')).single, isNotNull);
      expect((await readers('ext-deezer-artist-5')).single, isNull);
    });

    test(
      'the Deezer record has no Last.fm fields and the pool counts',
      () async {
        final rig = _Rig()
          ..relatedArtists = related6
          ..relatedRadio = relatedList
          ..relatedTop = ((id) async => [tk(id * 10 + 1, 'Rel$id', 'Top$id')]);
        await rig.start();

        final record = rig.notifier.lastRefill!;
        expect(record.lastFmOutcome, isNull);
        expect(record.lastFmSource, isNull);
        final deezerRecord = record.deezer!;
        expect(deezerRecord['poolSize'], greaterThan(0));
        expect(deezerRecord['listsUsed'], 13);
        expect(deezerRecord['relatedCount'], 6);
        expect(deezerRecord['skipped'], isFalse);
        expect(deezerRecord['likedSignals'], 0);
        expect(deezerRecord['msTotal'], isA<int>());
        expect(record.toJson()['deezer'], deezerRecord);
        expect(record.toJson().containsKey('lastFmOutcome'), isTrue);
        rig.verifyLastFmNeverCalled();
      },
    );

    test('a refill asks one fresh seed radio and refetches no pooled '
        'list', () async {
      final rig = _Rig()
        ..relatedArtists = related6
        ..relatedRadio = relatedList
        ..relatedTop = ((id) async => [tk(id * 10 + 1, 'Rel$id', 'Top$id')]);
      await rig.start();
      await rig.settle();
      clearInteractions(rig.deezer);

      rig.radio = () async => freshRadio();
      await rig.refill();

      verify(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: 40,
          cancelToken: any(named: 'cancelToken'),
          background: true,
          retryQuota: false,
        ),
      ).called(1);
      verifyNever(
        () => rig.deezer.getArtistRadio(
          any(),
          limit: 25,
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.getArtistTopTracks(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
      verifyNever(
        () => rig.deezer.getRelatedArtists(
          any(),
          limit: any(named: 'limit'),
          cancelToken: any(named: 'cancelToken'),
          background: any(named: 'background'),
          retryQuota: any(named: 'retryQuota'),
        ),
      );
    });

    test('deactivating while a top-up runs makes no further Deezer call '
        'and no state write', () async {
      final rig = _Rig()
        ..relatedArtists = related6
        ..relatedRadio = relatedList;
      final held = Completer<List<DeezerTrack>>();
      var topCalls = 0;
      rig.relatedTop = (id) {
        topCalls++;
        if (topCalls <= 6) return Future.error(transport());
        if (topCalls == 7) return held.future;
        return Future.value([tk(id, 'Rel$id', 'Top$id')]);
      };
      await rig.start();
      await rig.settle();
      expect(topCalls, 7, reason: 'the top-up waits on its first repair');
      final queued = _ids(rig.queue.queuedSongs);

      rig.notifier.deactivate();
      clearInteractions(rig.deezer);
      held.complete([tk(1, 'Rel31', 'Late')]);
      await rig.settle();

      verifyNoDeezerCalls(rig);
      expect(rig.state.active, isFalse);
      expect(_ids(rig.queue.queuedSongs), queued);
    });

    group('played-through signals', () {
      _Rig neighbourhoodRig([PreferredMixMode? mode]) =>
          (mode == null ? _Rig() : _Rig(mode: mode))
            ..relatedArtists = related6
            ..relatedRadio = relatedList
            ..relatedTop = ((id) async => [
              tk(id * 10 + 1, 'Rel$id', 'Top$id'),
            ]);
      List<String> relSongs(_Rig rig) => [
        for (final s in rig.queue.queuedSongs)
          if (s.artist!.startsWith('Rel')) s.id,
      ];
      String otherSong(_Rig rig) => rig.queue.queuedSongs
          .firstWhere((s) => !s.artist!.startsWith('Rel'))
          .id;
      void verifyLiked(_Rig rig, int artistId, {required int times}) => verify(
        () => rig.deezer.getArtistRadio(
          artistId,
          limit: 25,
          cancelToken: any(named: 'cancelToken'),
          background: true,
          retryQuota: false,
        ),
      ).called(times);
      // A distinct position each time: the stream drops repeated values.
      var ticks = 0;
      Future<void> playThrough(_Rig rig, String id) =>
          rig.play(id, position: Duration(seconds: 100 + ticks++));
      int? liked(_Rig rig) =>
          rig.notifier.lastRefill?.deezer?['likedSignals'] as int?;

      test('a neighbourhood song played past the threshold becomes a liked '
          'radio', () async {
        final rig = neighbourhoodRig();
        await rig.start();
        await rig.settle();
        clearInteractions(rig.deezer);
        final rel = relSongs(rig).first;
        await playThrough(rig, rel);
        await rig.play(otherSong(rig));
        await rig.refill();

        final id = int.parse(rel.substring(3, 5));
        verifyLiked(rig, id, times: 1);
        expect(liked(rig), 1);
      });

      test(
        'a skipped song, the anchor and a non-mix song never count',
        () async {
          final rig = neighbourhoodRig();
          await rig.start();
          await rig.settle();
          clearInteractions(rig.deezer);
          final rel = relSongs(rig);
          await rig.play('seed', position: const Duration(seconds: 100));
          await rig.play(rel[0], position: const Duration(seconds: 5));
          await rig.play('q-9', position: const Duration(seconds: 100));
          await rig.play(rel[1]);
          await rig.refill();

          verifyNever(
            () => rig.deezer.getArtistRadio(
              any(),
              limit: 25,
              cancelToken: any(named: 'cancelToken'),
              background: any(named: 'background'),
              retryQuota: any(named: 'retryQuota'),
            ),
          );
          expect(liked(rig), 0);
        },
      );

      test('only neighbourhood artists count, at most two, most recent '
          'first out', () async {
        final rig = neighbourhoodRig();
        await rig.start();
        await rig.settle();
        clearInteractions(rig.deezer);
        // One song per related artist ('RelNN-...').
        final byArtist = <String, String>{};
        for (final id in relSongs(rig)) {
          byArtist.putIfAbsent(id.substring(0, 5), () => id);
        }
        final rel = byArtist.values.toList();
        expect(rel.length, greaterThanOrEqualTo(3));
        for (final id in rel.take(3)) {
          await playThrough(rig, id);
        }
        await playThrough(rig, otherSong(rig));
        await rig.play('q-9');
        await rig.refill();

        int idOf(String song) => int.parse(song.substring(3, 5));
        verifyNever(
          () => rig.deezer.getArtistRadio(
            idOf(rel[0]),
            limit: 25,
            cancelToken: any(named: 'cancelToken'),
            background: true,
            retryQuota: false,
          ),
        );
        verifyLiked(rig, idOf(rel[1]), times: 1);
        verifyLiked(rig, idOf(rel[2]), times: 1);
        expect(liked(rig), 2);
      });

      test('a song played through while a refill runs is not lost', () async {
        final rig = neighbourhoodRig();
        await rig.start();
        await rig.settle();
        clearInteractions(rig.deezer);
        final rel = relSongs(rig).first;
        final held = Completer<List<DeezerTrack>>();
        rig.radio = () => held.future;
        unawaited(rig.refill());
        await pumpEventQueue();
        expect(rig.state.refilling, isTrue);

        await playThrough(rig, rel);
        await rig.play(otherSong(rig));
        rig.radio = () async => freshRadio();
        held.complete(freshRadio());
        while (rig.state.refilling) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await rig.refill();

        verifyLiked(rig, int.parse(rel.substring(3, 5)), times: 1);
      });

      test('Last.fm mode ignores played-through songs', () async {
        final rig = neighbourhoodRig(PreferredMixMode.sameVibesLastFm);
        await rig.start();
        await rig.settle();
        clearInteractions(rig.deezer);
        final first = rig.queue.queuedSongs.first.id;
        await playThrough(rig, first);
        await rig.play('q-9');
        await rig.refill();

        verifyNever(
          () => rig.deezer.getArtistRadio(
            any(),
            limit: any(named: 'limit'),
            cancelToken: any(named: 'cancelToken'),
            background: any(named: 'background'),
            retryQuota: any(named: 'retryQuota'),
          ),
        );
        expect(rig.notifier.lastRefill?.deezer, isNull);
      });
    });
  });
}

extension on DeezerTrack {
  DeezerTrack copyWithTitle(String title) =>
      DeezerTrack(id: id, title: title, artist: artist);
}
