import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/library/data/lastfm_artist_cache.dart';
import 'package:navis/src/features/player/domain/lyrics_matcher.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Hard maximum tracks fetched from Last.fm (supports the "show 10" view).
const int kArtistTopTracksMax = 10;

/// Minimum tracks visible before "Show more".
const int kArtistTopTracksCollapsed = 5;

/// search3 songs per query — fetch more candidates so studio and live
/// versions of the same song are both available for comparison.
const int _kSearchSongCount = 10;

/// Minimum combined title+artist score to accept a local Subsonic song
/// as a match for a Last.fm top track.
const double _kMinimumMatchScore = 0.55;

/// Maximum parallel search3 requests when resolving tracks.
const int _kResolutionParallelism = 4;

/// Score penalty applied to candidates that look like live or concert
/// recordings, to prefer studio album / EP / single versions.
const double _kLivePenalty = 0.20;

// ---------------------------------------------------------------------------
// Domain model
// ---------------------------------------------------------------------------

/// A Last.fm top track enriched with an optional locally-resolved
/// [Song] from the user's Subsonic library.
class ResolvedArtistTopTrack {
  const ResolvedArtistTopTrack({
    required this.rank,
    required this.title,
    required this.artist,
    this.listeners,
    this.resolvedSong,
  });

  /// 1-based chart position.
  final int rank;
  final String title;
  final String artist;
  final int? listeners;

  /// Best-matching Subsonic [Song] found in the server library, or `null`
  /// when no confident match was found.
  final Song? resolvedSong;

  bool get isLocallyResolved => resolvedSong != null;
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Fetches, caches, and resolves the top tracks for [artistName].
///
/// - Guard: returns an empty list immediately when no Last.fm API key is
///   configured at build time.
/// - Cache: raw Last.fm metadata is persisted to disk with a day-boundary
///   expiry (entries become stale when the calendar date changes in local
///   time).  The Subsonic resolution is always re-computed in-memory, so
///   stale song IDs can never accumulate on disk.
/// - Resolution: for each Last.fm track, a `search3` query is run against
///   the Subsonic server to find the best-matching local song.  Tracks that
///   cannot be matched above [_kMinimumMatchScore] are returned with
///   `resolvedSong == null` and resolved lazily at tap time by the UI.
///
/// Keyed by the artist's display name as stored in the Subsonic library.
final artistTopTracksProvider = FutureProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, String>(
      (ref, artistName) async {
        // Keep resolved data alive for 5 minutes after the last listener
        // drops — prevents the section from re-fetching every time it scrolls
        // in or out of view on the artist detail page (issue #31).
        Timer? disposeTimer;
        final keepAliveLink = ref.keepAlive();
        ref.onCancel(() {
          disposeTimer = Timer(
            const Duration(minutes: 5),
            keepAliveLink.close,
          );
        });
        ref.onResume(() {
          disposeTimer?.cancel();
          disposeTimer = null;
        });
        ref.onDispose(() => disposeTimer?.cancel());

        final hasKey = ref.watch(hasLastFmApiKeyProvider);
        if (!hasKey) return const [];

        final trimmedArtist = artistName.trim();
        if (trimmedArtist.isEmpty) return const [];

        // 1. Try the day-boundary disk cache first.
        final cached = await LastFmArtistCache.readCache(trimmedArtist);
        late final List<LastFmArtistTopTrack> rawTracks;
        if (cached != null && cached.isNotEmpty) {
          rawTracks = cached;
        } else {
          // 2. Fetch from Last.fm.
          final client = ref.read(lastFmApiClientProvider);
          if (client == null) return const [];
          final fetched = await client.getArtistTopTracks(
            artist: trimmedArtist,
            limit: kArtistTopTracksMax,
          );
          if (fetched.isEmpty) return const [];
          await LastFmArtistCache.writeCache(trimmedArtist, fetched);
          rawTracks = fetched;
        }

        // 3. Resolve each track against the Subsonic server library.
        final api = ref.read(subsonicApiProvider);
        if (api == null) {
          // No active session — return unresolved so the list still renders.
          return rawTracks
              .map(
                (t) => ResolvedArtistTopTrack(
                  rank: t.rank,
                  title: t.title,
                  artist: t.artist,
                  listeners: t.listeners,
                ),
              )
              .toList(growable: false);
        }

        final resolved = List<ResolvedArtistTopTrack?>.filled(
          rawTracks.length,
          null,
        );

        // Fan out in bounded batches to avoid saturating the server.
        for (
          var batchStart = 0;
          batchStart < rawTracks.length;
          batchStart += _kResolutionParallelism
        ) {
          final batchEnd = math.min(
            rawTracks.length,
            batchStart + _kResolutionParallelism,
          );
          final batchFutures =
              Iterable<int>.generate(
                batchEnd - batchStart,
                (i) => batchStart + i,
              ).map((idx) async {
                final track = rawTracks[idx];
                Song? bestSong;
                try {
                  final query = '${track.title} ${track.artist}'.trim();
                  final result = await api.search3(
                    query: query,
                    artistCount: 0,
                    albumCount: 0,
                    songCount: _kSearchSongCount,
                  );
                  bestSong = pickBestArtistTopTrackMatch(
                    track: track,
                    candidates: result.songs,
                  );
                } on Object catch (e) {
                  AppLogger.debug(
                    'artistTopTracksProvider: resolution error for '
                    '"${track.title}" by "${track.artist}": $e',
                  );
                }
                resolved[idx] = ResolvedArtistTopTrack(
                  rank: track.rank,
                  title: track.title,
                  artist: track.artist,
                  listeners: track.listeners,
                  resolvedSong: bestSong,
                );
              });

          await Future.wait(batchFutures);
        }

        final localCount = resolved
            .whereType<ResolvedArtistTopTrack>()
            .where((t) => t.isLocallyResolved)
            .length;
        AppLogger.debug(
          'artistTopTracksProvider: resolved $localCount/'
          '${rawTracks.length} tracks locally for "$trimmedArtist"',
        );
        return resolved.whereType<ResolvedArtistTopTrack>().toList(
          growable: false,
        );
      },
    );

// ---------------------------------------------------------------------------
// Matching helpers (package-private — also used by the widget for live
// fallback resolution at tap time).
// ---------------------------------------------------------------------------

/// Returns the best-matching [Song] from [candidates] for [track], or `null`
/// when no candidate exceeds [_kMinimumMatchScore].
///
/// Scoring priority: Albums / EPs / Singles > anything else > live recordings.
/// Two candidates with the same title/artist score are ranked by release type
/// via a penalty applied to live/concert/unplugged versions.
Song? pickBestArtistTopTrackMatch({
  required LastFmArtistTopTrack track,
  required List<Song> candidates,
}) {
  if (candidates.isEmpty) return null;

  final expectedTitle = normalizeMetadata(track.title);
  final expectedArtist = normalizeMetadata(track.artist);
  if (expectedTitle.isEmpty || expectedArtist.isEmpty) return null;

  Song? best;
  var bestScore = 0.0;

  for (final candidate in candidates) {
    final candidateTitle = normalizeMetadata(candidate.title);
    final candidateArtist = normalizeMetadata(candidate.artist ?? '');
    if (candidateTitle.isEmpty || candidateArtist.isEmpty) continue;

    final titleScore = _fieldScore(
      expected: expectedTitle,
      actual: candidateTitle,
      exactWeight: 0.58,
      partialWeight: 0.42,
      tokenWeight: 0.42,
    );
    final artistScore = _fieldScore(
      expected: expectedArtist,
      actual: candidateArtist,
      exactWeight: 0.42,
      partialWeight: 0.30,
      tokenWeight: 0.30,
    );
    var score = math.max(0.0, math.min(1.0, titleScore + artistScore));

    // Penalise live / concert / unplugged recordings so that studio album
    // versions (Albums, EPs, Singles) are selected when available.
    if (_isLiveVersion(candidate)) score = math.max(0.0, score - _kLivePenalty);

    if (score > bestScore) {
      bestScore = score;
      best = candidate;
    }
  }

  if (best == null || bestScore < _kMinimumMatchScore) return null;
  return best;
}

double _fieldScore({
  required String expected,
  required String actual,
  required double exactWeight,
  required double partialWeight,
  required double tokenWeight,
}) {
  if (expected == actual) return exactWeight;
  if (expected.contains(actual) || actual.contains(expected)) {
    return partialWeight;
  }
  return _tokenOverlap(expected, actual) * tokenWeight;
}

double _tokenOverlap(String a, String b) {
  final aTokens = a.split(' ').where((t) => t.isNotEmpty).toSet();
  final bTokens = b.split(' ').where((t) => t.isNotEmpty).toSet();
  if (aTokens.isEmpty || bTokens.isEmpty) return 0;
  final overlap = aTokens.intersection(bTokens).length;
  return overlap / math.max(aTokens.length, bTokens.length);
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
