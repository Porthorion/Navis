import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:navis/src/api/lastfm_api_client.dart';
import 'package:navis/src/utils/app_logger.dart';

/// Disk-backed, day-boundary cache for Last.fm artist top-track metadata.
///
/// Cache files are stored in the application support directory under the name
/// `lastfm_top_<hash>.json` where `<hash>` is a truncated SHA-256 of the
/// normalised artist name.  A cache entry is valid only for the current
/// calendar day (year/month/day in local time) **and** must match the
/// requested artist name.  Either condition failing causes a cache miss so a
/// fresh API call is made.
class LastFmArtistCache {
  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Returns the cached tracks for [artist] if the entry is still valid for
  /// today and belongs to the same artist, or `null` when the entry is
  /// absent / stale / mismatched.
  static Future<List<LastFmArtistTopTrack>?> readCache(String artist) async {
    try {
      final file = await _cacheFile(artist);
      if (!file.existsSync()) return null;

      final raw = file.readAsStringSync();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['date'] != _todayString()) {
        return null;
      }

      // Validate the stored artist matches the requested one.  This guards
      // against hash collisions and stale entries written before per-artist
      // validation was added.
      final cachedArtist = json['artist'] as String?;
      if (cachedArtist == null ||
          _normalizeArtist(cachedArtist) != _normalizeArtist(artist)) {
        AppLogger.debug(
          'LastFmArtistCache: artist mismatch — '
          'requested="${artist.trim()}" cached="$cachedArtist" — discarding',
        );
        return null;
      }

      final tracksRaw = json['tracks'] as List<dynamic>;
      final tracks = tracksRaw
          .map((t) {
            final m = t as Map<String, dynamic>;
            return LastFmArtistTopTrack(
              rank: (m['rank'] as num).toInt(),
              title: m['title'] as String,
              artist: m['artist'] as String,
              listeners: (m['listeners'] as num?)?.toInt(),
            );
          })
          .toList(growable: false);

      AppLogger.debug(
        'LastFmArtistCache: hit for "${artist.trim()}" '
        '(${tracks.length} tracks)',
      );
      return tracks;
    } on Object catch (e) {
      AppLogger.debug('LastFmArtistCache: read error for "$artist": $e');
      return null;
    }
  }

  /// Writes [tracks] to disk for [artist] tagged with today's date.
  ///
  /// Failures are silently swallowed — a missing cache file just triggers a
  /// fresh API call on the next load.
  static Future<void> writeCache(
    String artist,
    List<LastFmArtistTopTrack> tracks,
  ) async {
    if (tracks.isEmpty) return;
    try {
      final file = await _cacheFile(artist);
      final json = <String, dynamic>{
        'date': _todayString(),
        'artist': artist.trim(),
        'tracks': tracks
            .map(
              (t) => <String, dynamic>{
                'rank': t.rank,
                'title': t.title,
                'artist': t.artist,
                if (t.listeners != null) 'listeners': t.listeners,
              },
            )
            .toList(growable: false),
      };
      file.writeAsStringSync(jsonEncode(json));
      AppLogger.debug(
        'LastFmArtistCache: wrote ${tracks.length} tracks for '
        '"${artist.trim()}"',
      );
    } on Object catch (e) {
      AppLogger.debug('LastFmArtistCache: write error for "$artist": $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Returns the cache [File] for [artist], creating the support directory if
  /// it does not yet exist.
  static Future<File> _cacheFile(String artist) async {
    final dir = await getApplicationSupportDirectory();
    final key = _artistCacheKey(artist);
    return File('${dir.path}/lastfm_top_$key.json');
  }

  /// Produces a collision-resistant, filesystem-safe cache key from an artist
  /// name by hashing the normalised name with SHA-256 and truncating to 16
  /// hex characters.
  static String _artistCacheKey(String artist) {
    final normalized = _normalizeArtist(artist);
    final hash = sha256.convert(utf8.encode(normalized)).toString();
    return hash.substring(0, 16);
  }

  /// Lowercases and trims whitespace for consistent cache key generation and
  /// artist-name comparison.
  static String _normalizeArtist(String artist) {
    return artist.toLowerCase().trim();
  }

  /// Returns today's date as `"yyyy-MM-dd"` in local time.
  static String _todayString() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }
}
