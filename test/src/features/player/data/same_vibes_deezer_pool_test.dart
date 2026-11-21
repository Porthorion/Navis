import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/player/data/same_vibes_deezer_pool.dart';

// No fake_async: the pool is driven with an injected clock and delay.

DeezerTrack _t(int id, String title, int artistId) => DeezerTrack(
  id: id,
  title: title,
  artist: DeezerArtist(id: artistId, name: 'Artist $artistId'),
);

/// In-memory stand-in for the disk cache (same contract, no file I/O).
class _MemoryCache extends IntegrationJsonCache {
  new();

  final Map<String, Object?> _entries = <String, Object?>{};

  @override
  Future<IntegrationCacheHit?> read(String namespace, String key) async {
    final key0 = '$namespace/$key';
    return _entries.containsKey(key0)
        ? IntegrationCacheHit(value: _entries[key0], storedAt: DateTime.now())
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

class _FakeClient extends DeezerApiClient {
  new() : super(dio: Dio());

  /// `radio:<id>:<limit>`, `related:<id>`, `top:<id>`, `track:<id>`,
  /// `search:<query>`, in the order the pool asked.
  final List<String> calls = <String>[];
  final List<bool> backgrounds = <bool>[];
  final List<bool> searchRetryQuotas = <bool>[];

  /// Held until completed (checked after the call is recorded).
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  /// Throws once, then answers normally.
  final Map<String, Exception> failOnce = <String, Exception>{};
  final Set<String> failAlways = <String>{};

  List<int> relatedOfSeed = <int>[10, 11, 12, 13, 14, 15, 16, 17];
  List<DeezerTrack> seedRadio = [
    for (var i = 0; i < 4; i++) _t(100 + i, 'S$i', 1),
  ];
  List<DeezerTrack> searchResults = [_t(900, 'Seed Song', 1)];

  Future<void> _enter(String call, bool background) async {
    calls.add(call);
    backgrounds.add(background);
    if (gates[call] case final gate?) await gate.future;
    if (failOnce.remove(call) case final error?) throw error;
    if (failAlways.contains(call)) throw Exception('boom $call');
  }

  @override
  Future<List<DeezerTrack>> getArtistRadio(
    int artistId, {
    int limit = 40,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    await _enter('radio:$artistId:$limit', background);
    return artistId == 1
        ? seedRadio
        : [
            for (var i = 0; i < 3; i++)
              _t(artistId * 100 + i, 'R$artistId-$i', artistId),
          ];
  }

  @override
  Future<List<DeezerArtist>> getRelatedArtists(
    int artistId, {
    int limit = 20,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    await _enter('related:$artistId', background);
    return [
      for (final id in artistId == 1 ? relatedOfSeed : <int>[])
        DeezerArtist(id: id, name: 'Artist $id'),
    ];
  }

  @override
  Future<List<DeezerTrack>> getArtistTopTracks(
    int artistId, {
    int limit = 5,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    await _enter('top:$artistId', background);
    return [
      for (var i = 0; i < 3; i++)
        _t(artistId * 1000 + i, 'T$artistId-$i', artistId),
    ];
  }

  @override
  Future<DeezerTrack?> getTrack(
    int id, {
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    await _enter('track:$id', background);
    return DeezerTrack(
      id: id,
      title: 'x',
      artist: const DeezerArtist(id: 1, name: 'a'),
      bpm: 100,
    );
  }

  @override
  Future<List<DeezerTrack>> searchTracks(
    String query, {
    int limit = 100,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    searchRetryQuotas.add(retryQuota);
    await _enter('search:$query', background);
    return searchResults;
  }
}

class _FakeResolver extends DeezerArtistResolver {
  new(DeezerApiClient client) : super(client: client, cache: _MemoryCache());

  int? answer = 1;
  final List<Map<String, Object?>> asked = <Map<String, Object?>>[];

  @override
  Future<int?> resolve({
    required String artistId,
    required String name,
    Future<Iterable<String>> Function()? readLibraryAlbumTitles,
    CancelToken? cancelToken,
    bool background = false,
    bool retryQuota = true,
  }) async {
    asked.add({
      'artistId': artistId,
      'titles': readLibraryAlbumTitles != null,
      'background': background,
      'retryQuota': retryQuota,
    });
    return answer;
  }
}

class _Rig {
  new({this.songId = 'lib-1', bool withTitles = false}) {
    resolver = _FakeResolver(client);
    pool = SameVibesDeezerPool(
      client: client,
      catalog: DeezerCatalog(client: client, cache: _MemoryCache()),
      resolver: resolver,
      readLibraryAlbumTitles: withTitles ? () async => ['Album'] : null,
      elapsed: () => Duration.zero,
      delay: (wait) {
        delays.add(wait);
        return deadline.future;
      },
      runner: runner,
    );
  }

  final String songId;
  final _FakeClient client = _FakeClient();
  late final _FakeResolver resolver;
  late final SameVibesDeezerPool pool;
  final Completer<void> deadline = Completer<void>();
  final List<Duration> delays = <Duration>[];
  bool cancelled = false;

  SameVibesPoolSeed get seed => SameVibesPoolSeed(
    songId: songId,
    artistId: 'ar-1',
    artist: 'Seed Artist',
    title: 'Seed Song',
  );

  /// The `leg` flag of every request the pool made, in order.
  final List<bool> legs = <bool>[];

  Future<T> runner<T>(
    Future<T> Function(CancelToken cancelToken) request, {
    bool leg = false,
  }) {
    legs.add(leg);
    if (cancelled) {
      return Future.error(
        DioException.requestCancelled(
          requestOptions: RequestOptions(path: 'x'),
          reason: 'stopped',
        ),
      );
    }
    return request(CancelToken());
  }
}

const _fetchOrder = [
  'radio:10:25',
  'radio:11:25',
  'top:10',
  'radio:12:25',
  'radio:13:25',
  'top:11',
  'radio:14:25',
  'radio:15:25',
  'top:12',
  'top:13',
  'top:14',
  'top:15',
];

List<int> _ids(String prefix, List<String> calls) => [
  for (final c in calls)
    if (c.startsWith(prefix)) int.parse(c.split(':')[1]),
];

void main() {
  test('only the first batch and the refill radios are tied to the leg, the '
      'top-up stays with the mix (F4)', () async {
    final rig = _Rig();
    await rig.pool.firstBatch(rig.seed);
    expect(rig.legs, isNotEmpty);
    expect(rig.legs.every((leg) => leg), isTrue, reason: 'first batch');

    rig.legs.clear();
    await rig.pool.topUp([5000, 5001]);
    expect(rig.legs, isNotEmpty);
    expect(rig.legs.any((leg) => leg), isFalse, reason: 'top-up');

    rig.legs.clear();
    await rig.pool.refillLists([20, 21]);
    expect(rig.legs, [true, true, true], reason: 'seed radio + 2 liked');
  });

  test(
    'requests the lists in fetch order after the seed radio and related',
    () async {
      final rig = _Rig();
      final batch = await rig.pool.firstBatch(rig.seed);

      expect(batch, isNotNull);
      expect(rig.client.calls.take(2), ['radio:1:40', 'related:1']);
      final lists = rig.client.calls.skip(2).toList();
      // The two kinds start in the weight order (a top list pays one cache read
      // before its request, so its position among the radios may shift by one).
      expect(_ids('radio:', lists), [10, 11, 12, 13, 14, 15]);
      expect(_ids('top:', lists), [10, 11, 12, 13, 14, 15]);
      expect(lists.take(2), _fetchOrder.take(2));
      expect(lists, hasLength(_fetchOrder.length));
      expect(batch!.relatedArtistIds, [10, 11, 12, 13, 14, 15, 16, 17]);
      expect(batch.relatedLists, hasLength(6));
      expect(
        batch.relatedLists.every((l) => l.radio != null && l.top != null),
        isTrue,
      );
    },
  );

  test('returns at the soft deadline without waiting; a later arrival lands in the pool', () async {
    final rig = _Rig();
    rig.client.gates['top:11'] = Completer<void>();
    rig.client.gates['radio:15:25'] = Completer<void>();
    final done = rig.pool.firstBatch(rig.seed);
    await pumpEventQueue();
    expect(rig.delays, [const Duration(milliseconds: 2500)]);
    rig.deadline.complete();
    final batch = (await done)!;

    expect(batch.seedRadio, hasLength(4));
    expect(batch.relatedLists[1].top, isNull);
    expect(batch.relatedLists[1].radio, isNotNull);
    expect(batch.relatedLists[5].radio, isNull);
    expect(rig.pool.stats.deadlineHit, isTrue);
    expect(rig.pool.stats.listsUsed, 1 + 10);

    rig.client.gates['top:11']!.complete();
    await pumpEventQueue();
    expect(rig.pool.relatedLists[1].top, isNotNull);
    expect(rig.pool.stats.listsUsed, 1 + 11);
    // The snapshot handed out at the deadline is not mutated afterwards.
    expect(batch.relatedLists[1].top, isNull);
  });

  test(
    'null without a seed radio, null when the artist is not on Deezer',
    () async {
      final rig = _Rig()..client.seedRadio = [];
      expect(await rig.pool.firstBatch(rig.seed), isNull);
      final other = _Rig();
      other.resolver.answer = null;
      expect(await other.pool.firstBatch(other.seed), isNull);
      expect(other.client.calls, isEmpty);
    },
  );

  test('no related artists: only the seed radio', () async {
    final rig = _Rig()..client.relatedOfSeed = [];
    final batch = (await rig.pool.firstBatch(rig.seed))!;
    expect(rig.client.calls, ['radio:1:40', 'related:1']);
    expect(batch.relatedArtistIds, isEmpty);
    expect(
      batch.relatedLists.every((l) => l.radio == null && l.top == null),
      isTrue,
    );
  });

  test(
    'firstBatch makes no track or search call for library and ext seeds',
    () async {
      for (final songId in ['lib-1', 'ext-deezer-song-777']) {
        final rig = _Rig(songId: songId);
        await rig.pool.firstBatch(rig.seed);
        expect(
          rig.client.calls.where(
            (c) => c.startsWith('track:') || c.startsWith('search:'),
          ),
          isEmpty,
          reason: songId,
        );
      }
    },
  );

  test('topUp fetches the missing lists, then the seed track, then 24 features in rank order; a second topUp is silent', () async {
    final rig = _Rig();
    rig.client.failOnce['top:14'] = Exception('x');
    rig.client.failOnce['radio:15:25'] = Exception('x');
    await rig.pool.firstBatch(rig.seed);
    expect(rig.pool.relatedLists[4].top, isNull);
    final before = rig.client.calls.length;

    final ids = [for (var i = 0; i < 30; i++) 5000 + i];
    await rig.pool.topUp(ids);
    final added = rig.client.calls.skip(before).toList();
    expect(added.take(4), [
      'radio:15:25',
      'top:14',
      'search:Seed Artist Seed Song',
      'track:900',
    ]);
    expect(added.skip(4), [for (final id in ids.take(24)) 'track:$id']);
    // Every request, the seed-track search included, is background and a
    // quota answer is not retried.
    for (var i = before; i < rig.client.calls.length; i++) {
      expect(rig.client.backgrounds[i], isTrue, reason: rig.client.calls[i]);
    }
    expect(rig.client.searchRetryQuotas, [false]);
    expect(rig.pool.seedTrack?.bpm, 100);
    expect(rig.pool.featuresOf(5003)?.bpm, 100);
    expect(rig.pool.relatedLists[4].top, isNotNull);

    final after = rig.client.calls.length;
    await rig.pool.topUp(ids);
    // Only the 6 of 30 ids beyond the first 24 remain unknown.
    expect(rig.client.calls.skip(after), [
      for (final id in ids.skip(24)) 'track:$id',
    ]);
    final settled = rig.client.calls.length;
    await rig.pool.topUp(ids);
    await rig.pool.topUp(ids);
    expect(rig.client.calls.length, settled);
  });

  test('two concurrent topUps request each missing item once', () async {
    final rig = _Rig();
    rig.client.failOnce['top:10'] = Exception('x');
    await rig.pool.firstBatch(rig.seed);
    rig.client.calls.clear();
    final gate = rig.client.gates['top:10'] = Completer<void>();
    final a = rig.pool.topUp([5000, 5001]);
    final b = rig.pool.topUp([5000, 5001]);
    await pumpEventQueue();
    gate.complete();
    await Future.wait([a, b]);

    expect(rig.client.calls.where((c) => c == 'top:10'), hasLength(1));
    expect(rig.client.calls.where((c) => c == 'track:5000'), hasLength(1));
    expect(rig.client.calls.where((c) => c == 'track:5001'), hasLength(1));
    expect(
      rig.client.calls.where((c) => c == 'search:Seed Artist Seed Song'),
      hasLength(1),
    );
  });

  test('topUp stops at the first quota answer; the next one resumes', () async {
    final rig = _Rig();
    await rig.pool.firstBatch(rig.seed);
    rig.client.failOnce['track:5002'] = const DeezerApiException(code: 4);
    final ids = [5000, 5001, 5002, 5003, 5004];
    final before = rig.client.calls.length;

    await rig.pool.topUp(ids);
    expect(rig.client.calls.skip(before).last, 'track:5002');
    expect(rig.pool.featuresOf(5001), isNotNull);
    expect(rig.pool.featuresOf(5002), isNull);

    final resumed = rig.client.calls.length;
    await rig.pool.topUp(ids);
    expect(rig.client.calls.skip(resumed), [
      'track:5002',
      'track:5003',
      'track:5004',
    ]);
  });

  test('a seed track not on Deezer means no feature calls', () async {
    final rig = _Rig()
      ..client.searchResults = [_t(901, 'Other', 1), _t(902, 'Seed Song', 99)];
    await rig.pool.firstBatch(rig.seed);
    await rig.pool.topUp([5000, 5001]);
    final calls = rig.client.calls;
    expect(calls.where((c) => c.startsWith('search:')), hasLength(1));
    expect(calls.where((c) => c.startsWith('track:')), isEmpty);
    await rig.pool.topUp([5000]);
    expect(calls.where((c) => c.startsWith('search:')), hasLength(1));
  });

  test('an ext-deezer-song seed uses its id without a search', () async {
    final rig = _Rig(songId: 'ext-deezer-song-777');
    await rig.pool.firstBatch(rig.seed);
    await rig.pool.topUp([5000]);
    expect(rig.client.calls.where((c) => c.startsWith('search:')), isEmpty);
    expect(rig.client.calls, containsAllInOrder(['track:777', 'track:5000']));
  });

  test(
    'refillLists asks the seed radio and at most two liked radios',
    () async {
      final rig = _Rig();
      await rig.pool.firstBatch(rig.seed);
      rig.client.calls.clear();
      final refill = await rig.pool.refillLists([20, 21, 22]);
      expect(rig.client.calls, ['radio:1:40', 'radio:20:25', 'radio:21:25']);
      expect(refill!.likedRadios, hasLength(2));
      expect(rig.client.backgrounds.reversed.take(3), everyElement(isTrue));
    },
  );

  test(
    'refillLists lets a seed radio error propagate, a clean empty is null',
    () async {
      final rig = _Rig();
      await rig.pool.firstBatch(rig.seed);

      rig.client.failAlways.add('radio:1:40');
      await expectLater(rig.pool.refillLists([20]), throwsException);
      rig.client.failAlways.clear();
      rig.client.failOnce['radio:1:40'] = const DeezerApiException(code: 4);
      await expectLater(
        rig.pool.refillLists([20]),
        throwsA(isA<DeezerApiException>()),
      );

      rig.client.seedRadio = const [];
      expect(await rig.pool.refillLists([20]), isNull);

      final offDeezer = _Rig()..resolver.answer = null;
      expect(await offDeezer.pool.firstBatch(offDeezer.seed), isNull);
      expect(await offDeezer.pool.refillLists(const []), isNull);
    },
  );

  test(
    'a cancelled runner makes no further calls and does not throw',
    () async {
      final rig = _Rig();
      rig.client.failOnce['top:10'] = Exception('x');
      await rig.pool.firstBatch(rig.seed);
      final before = rig.client.calls.length;
      rig.cancelled = true;
      await rig.pool.topUp([5000]);
      await expectLater(
        rig.pool.refillLists([20]),
        throwsA(isA<DioException>()),
      );
      expect(rig.client.calls.length, before);
    },
  );

  test('the resolver gets the library album reader, foreground and without quota retries', () async {
    final rig = _Rig(withTitles: true);
    await rig.pool.firstBatch(rig.seed);
    expect(rig.resolver.asked.single, {
      'artistId': 'ar-1',
      'titles': true,
      'background': false,
      'retryQuota': false,
    });
    expect(rig.pool.deezerArtistIdFor('Artist 12'), 12);
    expect(rig.pool.deezerArtistIdFor('Seed Artist'), 1);
    expect(rig.pool.deezerArtistIdFor('Nobody'), isNull);
  });
}
