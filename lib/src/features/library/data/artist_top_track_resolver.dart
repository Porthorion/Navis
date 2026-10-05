import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/database/daos/library_dao.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/integrations/data/integration_call_recorder.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/catalog_source.dart';

/// Parallel `search3` requests while matching top songs.
const int kArtistTopTrackSearchWorkers = 4;

/// Songs requested per `search3`.
const int _kSearchSongCount = 10;

// Span names on `IntegrationCallRecorder`, for the diagnostics endpoint.
const String kTopSongsSpanPrefix = 'topSongs';
const String kTopSongsLocalMatchSpan = '$kTopSongsSpanPrefix.localMatch';
const String kTopSongsServerMatchSpan = '$kTopSongsSpanPrefix.serverMatch';

/// Matches an artist's top songs to library songs.
///
/// For each seed, in order of cost:
/// 1. a fresh remembered match whose song still exists (one DAO query for
///    all of them, shared with step 2);
/// 2. a Deezer track the library holds as `ext-deezer-song-<id>`;
/// 3. the local pass: the library songs that could match, scored by
///    [pickBestTrackMatch];
/// 4. `search3` on the server, by [kArtistTopTrackSearchWorkers] workers
///    pulling from one queue, sharing the caller's [CancelToken]. A seed
///    remembered as unmatched or remote within the last day skips it.
///
/// [resolve] emits once after the local pass when it found something and
/// server searches follow, and once at the end, so rows move at most twice. Results are remembered
/// in [ArtistTopTrackMatchStore]. Within the session, a search for the same
/// artist's seed that is running or recently finished (the section and the
/// "This Is" page) is shared rather than sent again.
class ArtistTopTrackResolver {
  new({
    required this._libraryDao,
    required this._api,
    required this._store,
    required this._recorder,
  });

  final LibraryDao _libraryDao;
  final SubsonicApiClient? _api;
  final ArtistTopTrackMatchStore _store;
  final IntegrationCallRecorder _recorder;

  /// Server searches of this session, running or finished, per artist and
  /// seed. The section and the "This Is" page share them, and a finished one
  /// is reused while it is as fresh as a remembered match would be.
  final Map<String, ({Future<_SearchOutcome> outcome, DateTime startedAt})>
  _searches = {};

  /// Forgets this session's searches, after a library sync.
  void forgetSearches() => _searches.clear();

  /// [artistId] keys the remembered matches and shared searches; another
  /// ranked list, such as Home's Trending, passes its own key. Only seeds
  /// [shouldSearch] accepts (all by default) go to the server, by
  /// [searchWorkers] workers. Spans are named `<spanPrefix>.localMatch` and
  /// `<spanPrefix>.serverMatch`.
  Stream<List<ResolvedArtistTopTrack>> resolve({
    required String artistId,
    required List<ArtistTopTrackSeed> seeds,
    required CancelToken cancelToken,
    int searchWorkers = kArtistTopTrackSearchWorkers,
    bool Function(ArtistTopTrackSeed seed)? shouldSearch,
    String spanPrefix = kTopSongsSpanPrefix,
  }) async* {
    if (seeds.isEmpty) {
      yield const <ResolvedArtistTopTrack>[];
      return;
    }
    final localTimer = Stopwatch()..start();
    final keys = seeds.map(ArtistTopTrackMatchStore.seedKey).toList();
    final songs = List<Song?>.filled(seeds.length, null);
    final done = List<bool>.filled(seeds.length, false);
    final updates = <String, ArtistTopTrackMatchEntry>{};
    // Read first: a library sync that clears the store during this run makes
    // its results stale, and the store then drops them.
    final generation = _store.generation;
    final remembered = await _store.load(artistId);

    // Steps 1 and 2: remembered songs and Deezer ids, in one query.
    final rowsById = <String, SongsTableData>{};
    try {
      final ids = <String>{
        for (final entry in remembered.values) ?entry.songId,
        for (final seed in seeds)
          if (seed.deezerTrackId case final id?) _deezerSongId(id),
      };
      for (final row in await _libraryDao.getSongsByIds(ids)) {
        if (row.serverDeletedAt == null) rowsById[row.id] = row;
      }
    } on Object catch (error) {
      AppLogger.debug('Top songs: remembered matches unreadable: $error');
    }
    var cached = 0;
    for (var i = 0; i < seeds.length; i++) {
      final entry = remembered[keys[i]];
      final row = entry?.songId == null ? null : rowsById[entry!.songId];
      if (row != null) {
        songs[i] = _songFromRow(row);
        done[i] = true;
        cached++;
        continue;
      }
      final deezerId = seeds[i].deezerTrackId;
      final deezerRow = deezerId == null
          ? null
          : rowsById[_deezerSongId(deezerId)];
      if (deezerRow != null) {
        songs[i] = _songFromRow(deezerRow);
        done[i] = true;
        updates[keys[i]] = ArtistTopTrackMatchEntry(
          songId: deezerRow.id,
          checkedAt: _store.now(),
        );
      }
    }

    // Step 3: the local pass, also for remembered unmatched and remote
    // seeds, since a sync may have brought a library copy.
    var candidateCount = 0;
    var localHits = 0;
    final open = [
      for (var i = 0; i < seeds.length; i++)
        if (!done[i]) i,
    ];
    if (open.isNotEmpty) {
      try {
        final candidates = await _libraryDao.getTrackMatchCandidates(
          open.map((i) => (title: seeds[i].title, artist: seeds[i].artist)),
        );
        candidateCount = candidates.length;
        final snapshot = await LocalTrackMatchSnapshot.fromSongsAsync(
          candidates,
        );
        for (final i in open) {
          final query = artistTopTrackMatchQuery(seeds[i]);
          final match = _pickWithHints(query, snapshot.candidatesFor(query));
          final song = match.song;
          if (match.isMatched && song != null) {
            songs[i] = song;
            done[i] = true;
            localHits++;
            updates[keys[i]] = ArtistTopTrackMatchEntry(
              songId: song.id,
              checkedAt: _store.now(),
            );
          }
        }
      } on Object catch (error) {
        AppLogger.debug('Top songs: local pass failed for $artistId: $error');
      }
    }

    // Remembered remote and unmatched results stand until they are a day old.
    final searchIndexes = <int>[];
    for (final i in open) {
      if (done[i]) continue;
      final entry = remembered[keys[i]];
      if (shouldSearch != null && !shouldSearch(seeds[i])) {
        // Never searched: keep a remembered remote match, else no song.
        if (entry?.remoteSong case final remote?) {
          songs[i] = remote;
          cached++;
        }
        done[i] = true;
      } else if (entry == null) {
        searchIndexes.add(i);
      } else if (!_staysValidWithoutLibraryRow(entry)) {
        // A remembered library song that is gone: search again.
        searchIndexes.add(i);
      } else {
        songs[i] = entry.remoteSong;
        done[i] = true;
        cached++;
      }
    }
    _recorder.span('$spanPrefix.localMatch', <String, int>{
      'seeds': seeds.length,
      'cached': cached,
      'candidates': candidateCount,
      'localHits': localHits,
    }, localTimer.elapsed);

    final api = _api;
    if (api == null || searchIndexes.isEmpty || cancelToken.isCancelled) {
      unawaited(_store.save(artistId, updates, generation: generation));
      yield _results(seeds, songs);
      return;
    }

    // Nothing to show yet would hide the section and flip the "This Is"
    // card until the searches finish; stay loading instead.
    if (songs.any((song) => song != null)) yield _results(seeds, songs);

    // Step 4: the server.
    final serverTimer = Stopwatch()..start();
    var searches = 0;
    var matched = 0;
    var remote = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < searchIndexes.length && !cancelToken.isCancelled) {
        final i = searchIndexes[next++];
        final outcome = await _search(
          api,
          artistId: artistId,
          key: keys[i],
          seed: seeds[i],
          cancelToken: cancelToken,
        );
        if (outcome.sent) searches++;
        if (!outcome.completed) continue;
        final song = outcome.song;
        songs[i] = song;
        if (song == null) {
          updates[keys[i]] = ArtistTopTrackMatchEntry.unmatched(
            checkedAt: _store.now(),
          );
          continue;
        }
        matched++;
        final isRemote = isExternalCatalogSource(
          id: song.id,
          apiIsExternal: song.isExternal,
        );
        if (isRemote) remote++;
        updates[keys[i]] = ArtistTopTrackMatchEntry(
          songId: song.id,
          remoteSong: isRemote ? song : null,
          checkedAt: _store.now(),
        );
      }
    }

    await Future.wait([
      for (var w = 0; w < math.min(searchWorkers, searchIndexes.length); w++)
        worker(),
    ]);
    _recorder.span('$spanPrefix.serverMatch', <String, int>{
      'unresolved': searchIndexes.length,
      'search3Calls': searches,
      'matched': matched,
      'remote': remote,
    }, serverTimer.elapsed);
    unawaited(_store.save(artistId, updates, generation: generation));
    yield _results(seeds, songs);
  }

  /// A remembered "unmatched" or remote song stays valid without a library
  /// row; a remembered library song does not.
  static bool _staysValidWithoutLibraryRow(ArtistTopTrackMatchEntry entry) =>
      !entry.isMatched || entry.remoteSong != null;

  Future<_SearchOutcome> _search(
    SubsonicApiClient api, {
    required String artistId,
    required String key,
    required ArtistTopTrackSeed seed,
    required CancelToken cancelToken,
  }) async {
    final shareKey = '$artistId\u001f$key';
    final known = _searches[shareKey];
    if (known != null &&
        _store.now().difference(known.startedAt) <
            ArtistTopTrackMatchStore.freshFor) {
      final outcome = (await known.outcome).shared();
      // A search cancelled by its own (disposed) caller is repeated.
      if (outcome.completed || cancelToken.isCancelled) return outcome;
    }
    final search = (
      outcome: _searchServer(api, seed, cancelToken),
      startedAt: _store.now(),
    );
    _searches[shareKey] = search;
    final outcome = await search.outcome;
    if (!outcome.completed && identical(_searches[shareKey], search)) {
      _searches.remove(shareKey);
    }
    return outcome;
  }

  Future<_SearchOutcome> _searchServer(
    SubsonicApiClient api,
    ArtistTopTrackSeed seed,
    CancelToken cancelToken,
  ) async {
    try {
      final result = await api.search3(
        query: '${seed.title} ${seed.artist}'.trim(),
        artistCount: 0,
        albumCount: 0,
        songCount: _kSearchSongCount,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled) return const _SearchOutcome.incomplete();
      return _SearchOutcome.found(
        pickBestArtistTopTrackMatch(
          track: artistTopTrackMatchQuery(seed),
          candidates: result.songs,
        ),
      );
    } on Object catch (error) {
      AppLogger.debug(
        'Top songs: search3 failed for "${seed.title}" by "${seed.artist}": '
        '$error',
      );
      return const _SearchOutcome.incomplete();
    }
  }

  static List<ResolvedArtistTopTrack> _results(
    List<ArtistTopTrackSeed> seeds,
    List<Song?> songs,
  ) => List<ResolvedArtistTopTrack>.unmodifiable([
    for (var i = 0; i < seeds.length; i++)
      ResolvedArtistTopTrack.fromSeed(seeds[i], song: songs[i]),
  ]);

  static String _deezerSongId(int deezerTrackId) =>
      'ext-deezer-song-$deezerTrackId';

  static Song _songFromRow(SongsTableData row) =>
      TrackMatchCandidate.fromTableSong(row).song;
}

class _SearchOutcome {
  const new found(this.song) : completed = true, sent = true;

  /// The search failed or was cancelled; nothing is remembered.
  const new incomplete() : song = null, completed = false, sent = true;

  const new _({required this.song, required this.completed}) : sent = false;

  final Song? song;
  final bool completed;

  /// This caller sent the request, rather than joining one in flight.
  final bool sent;

  _SearchOutcome shared() => _SearchOutcome._(song: song, completed: completed);
}

/// The matcher query for [seed]: title and artist, plus the album and length
/// when the source gives them.
TrackMatchQuery artistTopTrackMatchQuery(ArtistTopTrackSeed seed) =>
    TrackMatchQuery(
      title: seed.title,
      artist: seed.artist,
      album: seed.album,
      durationSeconds: seed.durationSeconds,
    );

/// The best of [candidates] (`search3` results) for [track], studio
/// recordings before live ones, or null.
Song? pickBestArtistTopTrackMatch({
  required TrackMatchQuery track,
  required List<Song> candidates,
}) {
  return _pickWithHints(
    track,
    candidates.map(TrackMatchCandidate.fromSong).toList(growable: false),
  ).song;
}

/// [pickBestTrackMatch] with the source's album and length as hints only.
///
/// They can raise a candidate (an equal title on the expected album wins),
/// but never reject one that title and artist alone accept: a Deezer album
/// ("... (Deluxe)") or a radio-edit length often differs from the library's.
TrackMatchResult _pickWithHints(
  TrackMatchQuery query,
  List<TrackMatchCandidate> candidates,
) {
  final ranked = _rankArtistCandidates(candidates);
  final hinted = pickBestTrackMatch(track: query, candidates: ranked);
  if (hinted.isMatched ||
      (query.album == null && query.durationSeconds == null)) {
    return hinted;
  }
  return pickBestTrackMatch(
    track: TrackMatchQuery(
      title: query.title,
      artist: query.artist,
      recordingMbid: query.recordingMbid,
    ),
    candidates: ranked,
  );
}

List<TrackMatchCandidate> _rankArtistCandidates(
  List<TrackMatchCandidate> candidates,
) {
  final ranked = candidates.toList(growable: false);
  ranked.sort((a, b) {
    final aLive = _isLiveVersion(a.song);
    final bLive = _isLiveVersion(b.song);
    if (aLive == bLive) return 0;
    return aLive ? 1 : -1;
  });
  return ranked;
}

/// Returns true when [song] appears to be a live recording or special
/// non-studio release (live, concert, acoustic set, unplugged, etc.).
///
/// Both the song title and the album name are checked so that a song titled
/// "Bohemian Rhapsody" on an album called "Live At Wembley" is also caught.
bool _isLiveVersion(Song song) {
  // Parenthetical / bracketed qualifiers in the title — e.g. "Song (Live)",
  // "Song [Live at Madison Square Garden]", "Song - Live Version".
  final titleExtra = RegExp(
    r'[\(\[\-]\s*live|\blive version\b|\blive recording\b|\bin concert\b'
    r'|\bunplugged\b|\bacoustic\s+(session|version|set)\b',
    caseSensitive: false,
  );

  // Album name signals: "Live", "Live At/In/From ...", "... Live",
  // "In Concert", "Unplugged", etc.
  final albumSignal = RegExp(
    r'\blive\b|\bin concert\b|\bunplugged\b|\bconcert\b',
    caseSensitive: false,
  );

  if (titleExtra.hasMatch(song.title)) return true;
  final albumName = song.album;
  if (albumName != null && albumSignal.hasMatch(albumName)) return true;
  return false;
}
