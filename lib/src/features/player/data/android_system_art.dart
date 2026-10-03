import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:navis/src/features/player/data/playback_art_cache.dart';
import 'package:navis/src/utils/credential_redaction.dart';

/// Downloads [coverArtId]'s cover from [artUri] into the local cover cache
/// and returns the file path, or `null` when it cannot.
typedef SystemArtFetch = Future<String?> Function(
  String coverArtId,
  Uri artUri,
);

/// The cached file of [coverArtId]'s cover, or `null` when it is not on disk.
typedef SystemArtLookup = String? Function(String coverArtId);

/// Hands Android's media session, notification and Android Auto cover art
/// without the account token.
///
/// A Subsonic cover URL carries the token and salt, and audio_service copies
/// `artUri` into the session metadata (`METADATA_KEY_DISPLAY_ICON_URI`) and
/// the browse and queue items, where any MediaController client can read it.
/// Such an `artUri` is replaced by `content://<package>.artwork/cover/<key>`,
/// which `NavisArtworkProvider` serves read-only from the cover cache
/// ([PlaybackArtCache]); Android Auto runs in another process and can open
/// it. Art without credentials (radio artwork) is passed through.
///
/// The content URI is published only once the cover is on disk; until then
/// the item has no art and the download is started. A URI the provider
/// cannot open yet makes audio_service put empty `METADATA_KEY_ALBUM_ART`
/// into the session, and the later update with the real bitmap keeps the
/// same URI: Bluetooth AVRCP treats it as unchanged and Android Auto does not
/// reload an unchanged URI, so both stayed blank (1.4.0). Going from no art
/// to art is a change both of them show.
class AndroidSystemArt {
  new({
    required this.authority,
    required this._fetch,
    required this._cachedPath,
  });

  /// `<applicationId>.artwork`, matching the manifest's provider.
  final String authority;
  final SystemArtFetch _fetch;
  final SystemArtLookup _cachedPath;

  static const _prefetchConcurrency = 6;

  /// Browse lists are answered after this long even if covers are still
  /// downloading; those covers appear the next time the list is shown.
  static const browseArtBudget = Duration(milliseconds: 1500);

  /// The cover id a Subsonic cover URL names, if [artUri] carries account
  /// credentials; `null` otherwise.
  static String? _credentialedCoverId(Uri? artUri) {
    if (artUri == null || !uriCarriesCredentials(artUri)) return null;
    return artUri.queryParameters['id'] ?? '';
  }

  /// [item] as the system may see it. With [prefetch] the cover download
  /// starts (or joins one in progress) when the cover is not cached yet.
  MediaItem forSystem(MediaItem item, {bool prefetch = false}) {
    final artUri = item.artUri;
    final coverArtId = _credentialedCoverId(artUri);
    if (coverArtId == null) return item;
    if (coverArtId.isEmpty) return item.copyWith(artUri: null);
    if (!_isCached(item, coverArtId)) {
      if (prefetch) unawaited(_fetch(coverArtId, artUri!));
      return item.copyWith(artUri: null);
    }
    return item.copyWith(
      artUri: Uri(
        scheme: 'content',
        host: authority,
        pathSegments: <String>['cover', PlaybackArtCache.fileKey(coverArtId)],
      ),
    );
  }

  /// NavisAudioHandler adds `artCacheFile` to the current item once its
  /// cover is on disk; other items are looked up in the cover cache.
  bool _isCached(MediaItem item, String coverArtId) =>
      item.extras?['artCacheFile'] is String || _cachedPath(coverArtId) != null;

  /// [items] as the system may see them, once their covers are cached or
  /// [budget] has passed. Covers still downloading are left out.
  Future<List<MediaItem>> forSystemList(
    List<MediaItem> items, {
    Duration budget = browseArtBudget,
  }) async {
    final pending = <(String, Uri)>[];
    final seen = <String>{};
    for (final item in items) {
      final coverArtId = _credentialedCoverId(item.artUri);
      if (coverArtId != null && coverArtId.isNotEmpty && seen.add(coverArtId)) {
        pending.add((coverArtId, item.artUri!));
      }
    }
    if (pending.isNotEmpty) {
      final downloads = _downloadAll(pending);
      await Future.any(<Future<void>>[downloads, Future<void>.delayed(budget)]);
    }
    return <MediaItem>[for (final item in items) forSystem(item)];
  }

  Future<void> _downloadAll(List<(String, Uri)> covers) async {
    var next = 0;
    Future<void> worker() async {
      while (next < covers.length) {
        final (coverArtId, artUri) = covers[next++];
        try {
          await _fetch(coverArtId, artUri);
        } on Object {
          // A missing cover only leaves that item without art.
        }
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < _prefetchConcurrency; i++) worker(),
    ]);
  }
}
