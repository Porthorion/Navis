import 'dart:async';

import 'package:dio/dio.dart';

import 'package:navis/src/api/deezer_api_client.dart';
import 'package:navis/src/features/integrations/data/deezer_artist_resolver.dart';
import 'package:navis/src/features/integrations/data/deezer_catalog.dart';
import 'package:navis/src/features/player/domain/same_vibes_ranking.dart';
import 'package:navis/src/utils/metadata_normalization.dart';

/// The mix's seed as the pool needs it: a library or `ext-deezer-song-<id>`
/// song id, the library artist id (null when unknown) and the names to match.
class SameVibesPoolSeed {
  const new({
    required this.songId,
    this.artistId,
    required this.artist,
    required this.title,
  });

  final String songId;
  final String? artistId;
  final String artist;
  final String title;
}

/// One related artist's lists; null = not fetched (yet).
typedef SameVibesPoolList = ({
  List<DeezerTrack>? radio,
  List<DeezerTrack>? top,
});

/// What [SameVibesDeezerPool.firstBatch] hands the ranker: a snapshot of the
/// pool at the soft deadline (later arrivals are not added to it).
class SameVibesPoolInputs {
  const new({
    required this.seedArtistId,
    required this.relatedArtistIds,
    required this.seedRadio,
    required this.relatedLists,
  });

  final int seedArtistId;
  final List<int> relatedArtistIds;
  final List<DeezerTrack> seedRadio;

  /// Index = related rank 0..5.
  final List<SameVibesPoolList> relatedLists;
}

/// Runs a request under the session's cancel token
/// (`RecommendationSession.withCancelToken`).
typedef SameVibesPoolRunner = Future<T> Function<T>(
  Future<T> Function(CancelToken cancelToken) request,
);

Future<T> _runWithFreshToken<T>(Future<T> Function(CancelToken) request) =>
    request(CancelToken());

/// The Deezer lists one Same Vibes mix ranks, fetched once and reused by every
/// refill. The pool fetches, it does not rank: the notifier passes it the
/// feature ids from [rankSameVibesPool]. One instance per mix.
///
/// [firstBatch] is foreground and ships at a soft deadline with what has
/// arrived; [topUp] and [refillLists] are background.
class SameVibesDeezerPool {
  new({
    required this._client,
    required this._catalog,
    required this._resolver,
    this._readLibraryAlbumTitles,
    Duration Function()? elapsed,
    Future<void> Function(Duration)? delay,
    SameVibesPoolRunner? runner,
  }) : _elapsed = elapsed ?? _wallClock(),
       _delay = delay ?? Future<void>.delayed,
       _run = runner ?? _runWithFreshToken;

  static const softDeadline = Duration(milliseconds: 2500);
  static const seedRadioLimit = 40;
  static const relatedRadioLimit = 25;
  static const maxFeatureCalls = 24;
  static const _relatedCount = 6;
  static const _likedRadioCount = 2;

  /// Weight order of the 12 related lists (see the plan, §3): `true` = top
  /// five, the number is the related rank.
  static const _fetchOrder = <(bool, int)>[
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

  static final _extSongPattern = RegExp(r'^ext-deezer-song-(\d+)$');

  static Duration Function() _wallClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  final DeezerApiClient _client;
  final DeezerCatalog _catalog;
  final DeezerArtistResolver _resolver;
  final Future<Iterable<String>> Function()? _readLibraryAlbumTitles;
  final Duration Function() _elapsed;
  final Future<void> Function(Duration) _delay;
  final SameVibesPoolRunner _run;

  SameVibesPoolSeed? _seed;
  int? _seedArtistId;
  List<int>? _relatedIds;
  List<DeezerTrack> _seedRadio = const [];
  final List<List<DeezerTrack>?> _radios = List.filled(_relatedCount, null);
  final List<List<DeezerTrack>?> _tops = List.filled(_relatedCount, null);
  final Map<String, int> _neighbourhood = <String, int>{};
  DeezerTrack? _seedTrack;
  var _noSeedTrack = false;
  final Map<int, DeezerTrack?> _features = <int, DeezerTrack?>{};

  /// Requests running now, so a topUp awaits a late first-batch list instead
  /// of asking again.
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  Future<void>? _topUp;

  var _deadlineHit = false;
  var _msLists = 0;

  /// The foreground first batch: seed radio ∥ related artists, then the 12
  /// related lists in fetch order, returned at [softDeadline] (from this call)
  /// or when all arrived. Null when the artist is not on Deezer or the seed
  /// radio is empty. Request errors of the seed radio and resolution propagate
  /// (the caller skips Deezer); a failed related list stays missing for
  /// [topUp]. Reads no track features.
  Future<SameVibesPoolInputs?> firstBatch(SameVibesPoolSeed seed) async {
    _seed = seed;
    final start = _elapsed();
    final artistId = await _resolveSeed(background: false);
    if (artistId == null) return null;

    final radio = _fetchRadio(artistId, seedRadioLimit, background: false);
    final related = _safe(_loadRelated(background: false));
    final seedRadio = await radio;
    await related;
    if (seedRadio.isEmpty) return null;
    _seedRadio = seedRadio;

    final fetches = [
      for (final (top, rank) in _fetchOrder)
        if (_missing(top, rank))
          _safe(_fetchList(top, rank, background: false)),
    ];
    final remaining = softDeadline - (_elapsed() - start);
    var hit = false;
    if (fetches.isNotEmpty) {
      await Future.any<void>([
        Future.wait(fetches),
        if (remaining > Duration.zero)
          _delay(remaining).then((_) => hit = true)
        else
          Future<void>.value().then((_) => hit = true),
      ]);
    }
    _deadlineHit = hit;
    _msLists = (_elapsed() - start).inMilliseconds;
    return SameVibesPoolInputs(
      seedArtistId: artistId,
      relatedArtistIds: List.unmodifiable(_relatedIds ?? const <int>[]),
      seedRadio: seedRadio,
      relatedLists: List.of(relatedLists),
    );
  }

  /// Background, idempotent, never throws. Fetches what the pool still lacks:
  /// related artists, every missing related list (fetch order), the seed's
  /// Deezer track, then `/track` features for up to [maxFeatureCalls] of
  /// [featureIds] not known yet, in the given order. Stops at the first quota
  /// answer or cancellation; the next call resumes. A running topUp is awaited
  /// first, so each item is requested once.
  Future<void> topUp(List<int> featureIds) {
    final previous = _topUp;
    final run = () async {
      if (previous != null) await previous;
      try {
        await _topUpBody(featureIds);
      } on Object {
        // A background repair never surfaces; the next refill retries.
      }
    }();
    return _topUp = run;
  }

  Future<void> _topUpBody(List<int> featureIds) async {
    if (_seedArtistId == null &&
        !await _step(() => _resolveSeed(background: true))) {
      return;
    }
    if (_seedArtistId == null) return;
    if (_relatedIds == null &&
        !await _step(() => _loadRelated(background: true))) {
      return;
    }
    for (final (top, rank) in _fetchOrder) {
      if (_missing(top, rank) &&
          !await _step(() => _fetchList(top, rank, background: true))) {
        return;
      }
    }
    if (_seedTrack == null &&
        !_noSeedTrack &&
        !await _step(() => _loadSeedTrack(background: true))) {
      return;
    }
    if (_seedTrack == null) return; // no seed track: no features at all
    final wanted = [
      for (final id in featureIds)
        if (!_features.containsKey(id)) id,
    ].take(maxFeatureCalls);
    for (final id in wanted) {
      final ok = await _step(() async {
        _features[id] = await _run(
          (token) => _catalog.track(
            id,
            cancelToken: token,
            background: true,
            retryQuota: false,
          ),
        );
      });
      if (!ok) return;
    }
  }

  /// Background: a fresh seed radio and the radios of up to two liked
  /// artists. Null on a clean empty (the artist is not on Deezer, or its seed
  /// radio is empty). A quota, transport or cancel error of the resolution or
  /// the seed radio propagates, as in [firstBatch]; a failed liked radio is
  /// just left out.
  Future<({List<DeezerTrack> seedRadio, List<List<DeezerTrack>> likedRadios})?>
  refillLists(List<int> likedArtistIds) async {
    final artistId = await _resolveSeed(background: true);
    if (artistId == null) return null;
    final seedRadioFuture = _fetchRadio(
      artistId,
      seedRadioLimit,
      background: true,
    );
    final liked = [
      for (final id in likedArtistIds.take(_likedRadioCount))
        _safeValue(_fetchRadio(id, relatedRadioLimit, background: true)),
    ];
    final seedRadio = await seedRadioFuture;
    final likedRadios = [
      for (final radio in await Future.wait(liked))
        if (radio != null && radio.isNotEmpty) radio,
    ];
    if (seedRadio.isEmpty) return null;
    _seedRadio = seedRadio;
    return (seedRadio: seedRadio, likedRadios: likedRadios);
  }

  /// The Deezer id of the seed artist or one of its related artists, by loose
  /// name, for the liked-song radios.
  int? deezerArtistIdFor(String artistName) =>
      _neighbourhood[looseArtistKey(artistName)];

  /// The lists gathered so far, index = related rank 0..5.
  List<SameVibesPoolList> get relatedLists => [
    for (var i = 0; i < _relatedCount; i++) (radio: _radios[i], top: _tops[i]),
  ];

  int? get seedArtistId => _seedArtistId;

  List<int> get relatedArtistIds => _relatedIds ?? const <int>[];

  /// The seed's `/track` record (bpm, date, explicit), once known.
  DeezerTrack? get seedTrack => _seedTrack;

  DeezerTrack? featuresOf(int trackId) => _features[trackId];

  ({
    int poolSize,
    int relatedCount,
    int listsUsed,
    int featuresUsed,
    bool deadlineHit,
    int msLists,
  })
  get stats {
    final keys = <String?>{};
    for (final list in [_seedRadio, ..._radios, ..._tops]) {
      for (final track in list ?? const <DeezerTrack>[]) {
        keys.add(sameVibesCanonicalSongKey(track.artist.name, track.title));
      }
    }
    keys.remove(null);
    return (
      poolSize: keys.length,
      relatedCount: _relatedIds?.length ?? 0,
      listsUsed:
          (_seedRadio.isEmpty ? 0 : 1) +
          _radios.where((l) => l != null).length +
          _tops.where((l) => l != null).length,
      featuresUsed: _features.values.where((t) => t != null).length,
      deadlineHit: _deadlineHit,
      msLists: _msLists,
    );
  }

  // --- internals ---

  bool _missing(bool top, int rank) =>
      (_relatedIds?.length ?? 0) > rank &&
      (top ? _tops : _radios)[rank] == null;

  /// Runs [step]; false (stop) on a quota answer or a cancellation, true
  /// otherwise (a failed single item is skipped).
  Future<bool> _step(Future<void> Function() step) async {
    try {
      await step();
      return true;
    } on DioException catch (error) {
      return !CancelToken.isCancel(error);
    } on DeezerApiException catch (error) {
      return !error.isQuotaExceeded;
    } on Object {
      return true;
    }
  }

  Future<void> _safe(Future<void> future) async {
    try {
      await future;
    } on Object {
      // Missing items are retried by topUp.
    }
  }

  Future<T?> _safeValue<T>(Future<T> future) async {
    try {
      return await future;
    } on Object {
      return null;
    }
  }

  Future<List<DeezerTrack>> _fetchRadio(
    int artistId,
    int limit, {
    required bool background,
  }) => _run(
    (token) => _client.getArtistRadio(
      artistId,
      limit: limit,
      cancelToken: token,
      background: background,
      retryQuota: false,
    ),
  );

  Future<void> _once(String key, Future<void> Function() fetch) async {
    final running = _inFlight[key];
    if (running != null) return await running;
    final future = fetch();
    _inFlight[key] = future;
    // `remove` returns the (possibly failed) future itself: drop it, never
    // hand it back from the callback (that would re-throw it unhandled).
    unawaited(
      future.then<void>(
        (_) async {
          unawaited(_inFlight.remove(key));
        },
        onError: (Object _) async {
          unawaited(_inFlight.remove(key));
        },
      ),
    );
    return await future;
  }

  Future<int?> _resolveSeed({required bool background}) async {
    final seed = _seed;
    if (_seedArtistId != null || seed == null) return _seedArtistId;
    await _once('resolve', () async {
      final id = await _run(
        (token) => _resolver.resolve(
          artistId: seed.artistId ?? '',
          name: seed.artist,
          readLibraryAlbumTitles: _readLibraryAlbumTitles,
          cancelToken: token,
          background: background,
          retryQuota: false,
        ),
      );
      if (id == null) return;
      _seedArtistId = id;
      _neighbourhood[looseArtistKey(seed.artist)] = id;
    });
    return _seedArtistId;
  }

  Future<void> _loadRelated({required bool background}) async {
    final artistId = _seedArtistId;
    if (artistId == null || _relatedIds != null) return;
    await _once('related', () async {
      final related = await _run(
        (token) => _catalog.relatedArtists(
          artistId,
          cancelToken: token,
          background: background,
          retryQuota: false,
        ),
      );
      _relatedIds = [for (final artist in related) artist.id];
      for (final artist in related) {
        _neighbourhood.putIfAbsent(
          looseArtistKey(artist.name),
          () => artist.id,
        );
      }
    });
  }

  Future<void> _fetchList(
    bool top,
    int rank, {
    required bool background,
  }) async {
    final ids = _relatedIds;
    if (ids == null || ids.length <= rank) return;
    final id = ids[rank];
    await _once('${top ? 'top' : 'radio'}:$rank', () async {
      if (top) {
        _tops[rank] = await _run(
          (token) => _catalog.artistTopFive(
            id,
            cancelToken: token,
            background: background,
            retryQuota: false,
          ),
        );
      } else {
        _radios[rank] = await _fetchRadio(
          id,
          relatedRadioLimit,
          background: background,
        );
      }
    });
  }

  /// The seed's `/track` record: the id inside `ext-deezer-song-<id>`, else the
  /// first search hit by the seed artist with the same version-free title.
  Future<void> _loadSeedTrack({required bool background}) async {
    final seed = _seed;
    final artistId = _seedArtistId;
    if (seed == null || artistId == null) return;
    await _once('seedTrack', () async {
      var id = int.tryParse(
        _extSongPattern
                .firstMatch(seed.songId.trim().toLowerCase())
                ?.group(1) ??
            '',
      );
      if (id == null) {
        final hits = await _run(
          (token) => _catalog.searchTracks(
            '${seed.artist} ${seed.title}',
            cancelToken: token,
            background: background,
            retryQuota: false,
          ),
        );
        final titleKey = songVersionTitleKey(seed.title);
        for (final hit in hits) {
          if (hit.artist.id == artistId &&
              songVersionTitleKey(hit.title) == titleKey) {
            id = hit.id;
            break;
          }
        }
      }
      final track = id == null
          ? null
          : await _run(
              (token) => _catalog.track(
                id!,
                cancelToken: token,
                background: background,
                retryQuota: false,
              ),
            );
      if (track == null) {
        _noSeedTrack = true;
      } else {
        _seedTrack = track;
        _features[track.id] = track;
      }
    });
  }
}
