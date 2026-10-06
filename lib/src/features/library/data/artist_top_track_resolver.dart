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
import 'package:navis/src/features/library/data/provisional_search_songs.dart';
import 'package:navis/src/features/library/domain/artist_top_track.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/catalog_source.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Parallel `search3` requests while matching top songs.
const int kArtistTopTrackSearchWorkers = 4;

/// Songs requested per `search3`.
const int _kSearchSongCount = 10;

// Span names on `IntegrationCallRecorder`, for the diagnostics endpoint.
const String kTopSongsSpanPrefix = 'topSongs';
const String kTopSongsLocalMatchSpan = '$kTopSongsSpanPrefix.localMatch';
const String kTopSongsServerMatchSpan = '$kTopSongsSpanPrefix.serverMatch';

/// Matches a ranked list of songs (an artist's top songs, Home's Trending
/// Now) to library songs, the way the ListenBrainz weekly playlists match
/// theirs.
///
/// For each seed, in order of cost:
/// 1. a remembered match whose song still exists (one DAO query for all of
///    them, shared with step 2);
/// 2. a Deezer track the library holds as `ext-deezer-song-<id>`;
/// 3. the local pass: the library songs that could match, scored by
///    [pickBestTrackMatch]. Remembered unmatched and remote seeds take it
///    too, so a library copy synced since replaces them;
/// 4. `search3` on the server, by the caller's number of workers pulling
///    from one queue and sharing its [CancelToken]. A copy on the server is
///    preferred over an equally good remote one. A seed remembered as
///    unmatched or remote within the last day skips it. A remembered remote
///    match that is older is searched again only for a copy on the server:
///    it is never replaced by another remote result or lost to a failed
///    search. Server copies the library does not hold yet are stored as
///    provisional rows ([persistProvisionalSearchSongs]), so the next pass
///    finds them locally.
///
/// [resolve] emits once after the local pass when server searches follow
/// (and it found something, or the caller asks for pending rows), with the
/// rows still searched marked [ResolvedArtistTopTrack.isMatching]; on
/// request after every few finished searches; and once at the end. Results
/// are remembered in [ArtistTopTrackMatchStore]. Within the session, a
/// search for the same list's seed that is running or recently finished
/// (the section and the "This Is" page) is shared rather than sent again.
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
  ///
  /// [researchUnmatched] searches remembered unmatched seeds again whatever
  /// their age (a manual refresh). [yieldPendingRows] emits the local pass
  /// even when no row has a song yet. [progressEvery] also emits after that
  /// many finished searches.
  Stream<List<ResolvedArtistTopTrack>> resolve({
    required String artistId,
    required List<ArtistTopTrackSeed> seeds,
    required CancelToken cancelToken,
    int searchWorkers = kArtistTopTrackSearchWorkers,
    bool Function(ArtistTopTrackSeed seed)? shouldSearch,
    String spanPrefix = kTopSongsSpanPrefix,
    bool researchUnmatched = false,
    bool yieldPendingRows = false,
    int? progressEvery,
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
    // Remote songs the library holds as rows (a remote match that was
    // played, or stored when its menu opened). They play, but stay
    // upgradeable: the local pass and the daily server check still run.
    final heldRemote = <int>{};
    for (var i = 0; i < seeds.length; i++) {
      final entry = remembered[keys[i]];
      final row = entry?.songId == null ? null : rowsById[entry!.songId];
      if (row != null) {
        songs[i] = _songFromRow(row);
        if (_isRemote(songs[i]!)) {
          heldRemote.add(i);
        } else {
          done[i] = true;
          cached++;
        }
        continue;
      }
      final deezerId = seeds[i].deezerTrackId;
      final deezerRow = deezerId == null
          ? null
          : rowsById[_deezerSongId(deezerId)];
      if (deezerRow != null) {
        songs[i] = _songFromRow(deezerRow);
        if (_isRemote(songs[i]!)) {
          heldRemote.add(i);
          continue;
        }
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
          // Remote rows are never library copies. (The DAO already leaves
          // out provisional rows, which is how remote songs are stored.)
          final match = _pickWithHints(
            query,
            snapshot
                .candidatesFor(query)
                .where(
                  (candidate) =>
                      !(candidate.tableSong?.isExternal ?? false) &&
                      !_isRemote(candidate.song),
                )
                .toList(growable: false),
          );
          final song = match.song;
          if (match.isMatched && song != null) {
            songs[i] = song;
            done[i] = true;
            heldRemote.remove(i);
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
    // Remote matches searched again only for a copy on the server.
    final upgradeOnly = <int>{};
    for (final i in open) {
      if (done[i]) continue;
      final entry = remembered[keys[i]];
      if (shouldSearch != null && !shouldSearch(seeds[i])) {
        // Never searched: keep a remote match, else no song.
        if (heldRemote.contains(i)) {
          cached++;
        } else if (entry?.remoteSong case final remote?) {
          songs[i] = remote;
          cached++;
        }
        done[i] = true;
      } else if (heldRemote.contains(i)) {
        // A remote song held as a row: checked on the server for a copy
        // once a day, like a remembered remote match.
        cached++;
        if (entry != null && entry.isMatched && _store.isFresh(entry)) {
          done[i] = true;
        } else {
          searchIndexes.add(i);
          upgradeOnly.add(i);
        }
      } else if (entry == null) {
        searchIndexes.add(i);
      } else if (!_staysValidWithoutLibraryRow(entry)) {
        // A remembered library song that is gone: search again.
        searchIndexes.add(i);
      } else if (entry.remoteSong case final remote?) {
        songs[i] = remote;
        cached++;
        if (_store.isFresh(entry)) {
          done[i] = true;
        } else {
          searchIndexes.add(i);
          upgradeOnly.add(i);
        }
      } else if (_store.isFresh(entry) && !researchUnmatched) {
        done[i] = true;
        cached++;
      } else {
        searchIndexes.add(i);
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

    final matching = List<bool>.filled(seeds.length, false);
    for (final i in searchIndexes) {
      matching[i] = true;
    }
    // Nothing to show yet would hide the section and flip the "This Is"
    // card until the searches finish; stay loading instead, unless the
    // caller shows rows that are still matching.
    if (yieldPendingRows || songs.any((song) => song != null)) {
      yield _results(seeds, songs, matching: matching);
    }

    // Step 4: the server.
    final serverTimer = Stopwatch()..start();
    var searches = 0;
    var matched = 0;
    var remote = 0;
    var upgraded = 0;
    var next = 0;
    var finishedSinceEmit = 0;
    final serverCopies = <String, Song>{};
    final progress = StreamController<List<ResolvedArtistTopTrack>>();
    Future<void> worker() async {
      while (next < searchIndexes.length && !cancelToken.isCancelled) {
        final i = searchIndexes[next++];
        final upgrade = upgradeOnly.contains(i);
        final outcome = await _search(
          api,
          artistId: artistId,
          key: keys[i],
          seed: seeds[i],
          cancelToken: cancelToken,
          upgradeOnly: upgrade,
          reuseFinished: !researchUnmatched,
        );
        matching[i] = false;
        if (outcome.sent) searches++;
        if (outcome.completed) {
          final song = outcome.song;
          if (song == null) {
            // No copy on the server: the remote match stays, rechecked in a
            // day; otherwise the song is unmatched.
            final kept = upgrade ? songs[i] : null;
            updates[keys[i]] = kept == null
                ? ArtistTopTrackMatchEntry.unmatched(checkedAt: _store.now())
                : ArtistTopTrackMatchEntry(
                    songId: kept.id,
                    remoteSong: kept,
                    checkedAt: _store.now(),
                  );
          } else {
            songs[i] = song;
            matched++;
            if (upgrade) upgraded++;
            final isRemote = isExternalCatalogSource(
              id: song.id,
              apiIsExternal: song.isExternal,
            );
            if (isRemote) remote++;
            if (isServerAddressableSongId(song.id)) {
              serverCopies[song.id] = song;
            }
            updates[keys[i]] = ArtistTopTrackMatchEntry(
              songId: song.id,
              remoteSong: isRemote ? song : null,
              checkedAt: _store.now(),
            );
          }
        }
        if (progressEvery != null &&
            ++finishedSinceEmit >= progressEvery &&
            matching.contains(true) &&
            !cancelToken.isCancelled) {
          finishedSinceEmit = 0;
          progress.add(_results(seeds, songs, matching: matching));
        }
      }
    }

    unawaited(
      Future.wait([
        for (var w = 0; w < math.min(searchWorkers, searchIndexes.length); w++)
          worker(),
      ]).whenComplete(progress.close),
    );
    yield* progress.stream;
    if (serverCopies.isNotEmpty && !cancelToken.isCancelled) {
      try {
        await persistProvisionalSearchSongs(_libraryDao, serverCopies.values);
      } on Object catch (error) {
        AppLogger.debug('Top songs: server copies not stored: $error');
      }
    }
    _recorder.span('$spanPrefix.serverMatch', <String, int>{
      'unresolved': searchIndexes.length,
      'search3Calls': searches,
      'matched': matched,
      'remote': remote,
      'upgradeChecks': upgradeOnly.length,
      'upgraded': upgraded,
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
    required bool upgradeOnly,
    required bool reuseFinished,
  }) async {
    final shareKey = '$artistId\u001f$key${upgradeOnly ? '\u001fupgrade' : ''}';
    final known = _searches[shareKey];
    if (known != null &&
        reuseFinished &&
        _store.now().difference(known.startedAt) <
            ArtistTopTrackMatchStore.freshFor) {
      final outcome = (await known.outcome).shared();
      // A search cancelled by its own (disposed) caller is repeated.
      if (outcome.completed || cancelToken.isCancelled) return outcome;
    }
    final search = (
      outcome: _searchServer(api, seed, cancelToken, upgradeOnly: upgradeOnly),
      startedAt: _store.now(),
    );
    _searches[shareKey] = search;
    final outcome = await search.outcome;
    if (!outcome.completed && identical(_searches[shareKey], search)) {
      _searches.remove(shareKey);
    }
    return outcome;
  }

  /// One `search3`. A copy on the server is preferred over an equally good
  /// remote one; with [upgradeOnly] only a copy on the server is taken.
  Future<_SearchOutcome> _searchServer(
    SubsonicApiClient api,
    ArtistTopTrackSeed seed,
    CancelToken cancelToken, {
    required bool upgradeOnly,
  }) async {
    try {
      final result = await api.search3(
        query: '${seed.title} ${seed.artist}'.trim(),
        artistCount: 0,
        albumCount: 0,
        songCount: _kSearchSongCount,
        cancelToken: cancelToken,
      );
      if (cancelToken.isCancelled) return const _SearchOutcome.incomplete();
      final query = artistTopTrackMatchQuery(seed);
      final onServer = result.songs
          .where(
            (song) => !isExternalCatalogSource(
              id: song.id,
              apiIsExternal: song.isExternal,
            ),
          )
          .toList(growable: false);
      var match = onServer.isEmpty
          ? null
          : pickBestArtistTopTrackMatch(track: query, candidates: onServer);
      if (match == null && !upgradeOnly) {
        match = pickBestArtistTopTrackMatch(
          track: query,
          candidates: result.songs,
        );
      }
      return _SearchOutcome.found(match);
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
    List<Song?> songs, {
    List<bool>? matching,
  }) => List<ResolvedArtistTopTrack>.unmodifiable([
    for (var i = 0; i < seeds.length; i++)
      ResolvedArtistTopTrack.fromSeed(
        seeds[i],
        song: songs[i],
        isMatching: songs[i] == null && (matching?[i] ?? false),
      ),
  ]);

  static String _deezerSongId(int deezerTrackId) =>
      'ext-deezer-song-$deezerTrackId';

  /// The row as a song, keeping whether it comes from a remote catalogue.
  static Song _songFromRow(SongsTableData row) =>
      // A row's id prefix still decides when the flag is unset.
      TrackMatchCandidate.fromTableSong(row).song
          .copyWith(isExternal: row.isExternal ? true : null);

  static bool _isRemote(Song song) =>
      isExternalCatalogSource(id: song.id, apiIsExternal: song.isExternal);
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
