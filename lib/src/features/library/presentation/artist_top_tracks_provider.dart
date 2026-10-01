import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/library/data/lastfm_artist_cache.dart';
import 'package:navis/src/features/library/data/local_track_matcher.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/sync_diagnostics_overrides.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Hard maximum tracks fetched from Last.fm for the full artist playlist.
const int kArtistTopTracksPlaylistMax = 50;

/// Maximum tracks shown in the artist detail Top Tracks section.
const int kArtistTopTracksSectionMax = 10;

/// Minimum tracks visible before "Show more".
const int kArtistTopTracksCollapsed = 5;

/// search3 songs per query; local library matching runs first.
const int _kSearchSongCount = 10;

/// Maximum parallel search3 requests when resolving tracks.
const int _kResolutionParallelism = 4;

// ---------------------------------------------------------------------------
// Domain model
// ---------------------------------------------------------------------------

/// A Last.fm top track enriched with an optional locally-resolved
/// [Song] from the user's Subsonic library.
class ResolvedArtistTopTrack {
  const new({
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

/// Fetches, caches, and resolves the top tracks for an artist name.
///
/// - Guard: returns an empty list immediately when no Last.fm API key is
///   configured at build time.
/// - Cache: raw Last.fm metadata is persisted to disk with a rolling 24-hour
///   expiry. The Subsonic resolution is always re-computed in-memory, so stale
///   song IDs can never accumulate on disk.
/// - Resolution: Last.fm tracks are matched against the local song snapshot
///   first. A bounded `search3` pass only runs for unresolved tracks.
///
/// Keyed by the artist's display name as stored in the Subsonic library.
final artistTopTracksRawProvider = FutureProvider.autoDispose
    .family<List<LastFmArtistTopTrack>, String>((ref, artistName) async {
      // Keep resolved data alive for 5 minutes after the last listener
      // drops — prevents the section from re-fetching every time it scrolls
      // in or out of view on the artist detail page (issue #31).
      Timer? disposeTimer;
      final keepAliveLink = ref.keepAlive();
      ref.onCancel(() {
        disposeTimer = Timer(const Duration(minutes: 5), keepAliveLink.close);
      });
      ref.onResume(() {
        disposeTimer?.cancel();
        disposeTimer = null;
      });
      ref.onDispose(() => disposeTimer?.cancel());

      final usePresentationFixture = ref.watch(
        syncDiagnosticsOverridesProvider.select(
          (overrides) => overrides.artistTopTracksPresentationFixture,
        ),
      );
      if (usePresentationFixture) {
        return const <LastFmArtistTopTrack>[
          LastFmArtistTopTrack(
            rank: 1,
            title: 'North Star',
            artist: 'Navis demo artist',
            listeners: 482910,
          ),
          LastFmArtistTopTrack(
            rank: 2,
            title: 'Afterglow',
            artist: 'Navis demo artist',
            listeners: 318745,
          ),
          LastFmArtistTopTrack(
            rank: 3,
            title: 'Blue Hour',
            artist: 'Navis demo artist',
            listeners: 245180,
          ),
          LastFmArtistTopTrack(
            rank: 4,
            title: 'Slow Motion',
            artist: 'Navis demo artist',
            listeners: 198352,
          ),
        ];
      }

      final hasKey = ref.watch(hasLastFmApiKeyProvider);
      if (!hasKey) return const [];

      final trimmedArtist = artistName.trim();
      if (trimmedArtist.isEmpty) return const [];

      // 1. Try the rolling 24-hour disk cache first.
      final cached = await LastFmArtistCache.readCache(
        trimmedArtist,
        limit: kArtistTopTracksPlaylistMax,
      );
      if (cached != null && cached.isNotEmpty) {
        return cached;
      }

      // 2. Fetch from Last.fm.
      final client = ref.read(lastFmApiClientProvider);
      if (client == null) return const [];
      final fetched = await client.getArtistTopTracks(
        artist: trimmedArtist,
        limit: kArtistTopTracksPlaylistMax,
      );
      if (fetched.isEmpty) return const [];
      await LastFmArtistCache.writeCache(
        trimmedArtist,
        fetched,
        limit: kArtistTopTracksPlaylistMax,
      );
      return fetched;
    });

final artistTopTracksProvider = FutureProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, String>((ref, artistName) async {
      final resolvedTracks = await ref.watch(
        _artistTopTracksResolvedAllProvider(artistName).future,
      );
      return resolvedTracks
          .take(kArtistTopTracksSectionMax)
          .toList(growable: false);
    });

final artistTopTracksPlaylistProvider = FutureProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, String>((ref, artistName) async {
      return ref.watch(_artistTopTracksResolvedAllProvider(artistName).future);
    });

final _artistTopTracksResolvedAllProvider = FutureProvider.autoDispose
    .family<List<ResolvedArtistTopTrack>, String>((ref, artistName) async {
      final rawTracks = await ref.watch(
        artistTopTracksRawProvider(artistName).future,
      );
      return _resolveArtistTopTracks(ref, artistName, rawTracks);
    });

Future<List<ResolvedArtistTopTrack>> _resolveArtistTopTracks(
  Ref ref,
  String artistName,
  List<LastFmArtistTopTrack> rawTracks,
) async {
  if (rawTracks.isEmpty) return const [];

  final api = ref.read(subsonicApiProvider);
  final resolved = rawTracks
      .map(
        (track) => ResolvedArtistTopTrack(
          rank: track.rank,
          title: track.title,
          artist: track.artist,
          listeners: track.listeners,
        ),
      )
      .toList(growable: true);

  try {
    // Only songs that could match these tracks, not the whole library.
    final songs = await ref
        .read(navisDatabaseProvider)
        .libraryDao
        .getTrackMatchCandidates(
          rawTracks.map((track) {
            final query = _artistTopTrackMatchQuery(track);
            return (title: query.title, artist: query.artist);
          }),
        );
    final snapshot = await LocalTrackMatchSnapshot.fromSongsAsync(songs);
    for (var index = 0; index < rawTracks.length; index++) {
      final track = rawTracks[index];
      final match = pickBestTrackMatch(
        track: _artistTopTrackMatchQuery(track),
        candidates: _rankArtistCandidates(
          snapshot.candidatesFor(_artistTopTrackMatchQuery(track)),
        ),
      );
      if (match.isMatched) {
        resolved[index] = _resolvedTrack(track, match.song);
      }
    }
  } on Object catch (e) {
    AppLogger.debug(
      'artistTopTracksProvider: local snapshot resolution failed for '
      '"${artistName.trim()}": $e',
    );
  }

  if (api == null) {
    return List<ResolvedArtistTopTrack>.unmodifiable(resolved);
  }

  final unresolvedIndexes = <int>[
    for (var index = 0; index < resolved.length; index++)
      if (!resolved[index].isLocallyResolved) index,
  ];

  // Fan out unresolved tracks in bounded batches to avoid saturating the server.
  for (
    var batchStart = 0;
    batchStart < unresolvedIndexes.length;
    batchStart += _kResolutionParallelism
  ) {
    final batchEnd = math.min(
      unresolvedIndexes.length,
      batchStart + _kResolutionParallelism,
    );
    final batchFutures =
        Iterable<int>.generate(
          batchEnd - batchStart,
          (i) => unresolvedIndexes[batchStart + i],
        ).map((index) async {
          final track = rawTracks[index];
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
          if (bestSong != null) {
            resolved[index] = _resolvedTrack(track, bestSong);
          }
        });

    await Future.wait(batchFutures);
  }

  final localCount = resolved
      .whereType<ResolvedArtistTopTrack>()
      .where((t) => t.isLocallyResolved)
      .length;
  AppLogger.debug(
    'artistTopTracksProvider: resolved $localCount/'
    '${rawTracks.length} tracks locally for "${artistName.trim()}"',
  );
  return List<ResolvedArtistTopTrack>.unmodifiable(resolved);
}

// ---------------------------------------------------------------------------
// Matching helpers (also used by widgets for live fallback resolution).
// ---------------------------------------------------------------------------

ResolvedArtistTopTrack _resolvedTrack(LastFmArtistTopTrack track, Song? song) {
  return ResolvedArtistTopTrack(
    rank: track.rank,
    title: track.title,
    artist: track.artist,
    listeners: track.listeners,
    resolvedSong: song,
  );
}

TrackMatchQuery _artistTopTrackMatchQuery(LastFmArtistTopTrack track) {
  return TrackMatchQuery(title: track.title, artist: track.artist);
}

Song? pickBestArtistTopTrackMatch({
  required LastFmArtistTopTrack track,
  required List<Song> candidates,
}) {
  final match = pickBestTrackMatch(
    track: _artistTopTrackMatchQuery(track),
    candidates: _rankArtistCandidates(
      candidates.map(TrackMatchCandidate.fromSong).toList(growable: false),
    ),
  );
  return match.song;
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
