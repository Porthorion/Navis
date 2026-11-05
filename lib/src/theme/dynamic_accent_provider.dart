import 'dart:async';

import 'package:audio_service/audio_service.dart'
    show AudioServiceRepeatMode, AudioServiceShuffleMode;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/settings/domain/app_settings.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

final dynamicAccentEnabledProvider = Provider<bool>((ref) {
  return ref.watch(dynamicAlbumColorEnabledProvider);
});

/// Sentinel source: the playing song's row is still loading, so the seed
/// provider holds its previous value instead of resolving.
const _pendingDynamicAccentSource = 'pending';

final _dynamicAccentSourceProvider = Provider<String?>((ref) {
  if (!ref.watch(dynamicAccentEnabledProvider)) {
    return null;
  }

  final playback = ref.watch(
    playerStateProvider.select(
      (snapshot) => (
        isRadioMode: snapshot.isRadioMode,
        currentSongId: snapshot.currentSongId,
        radioArtUrl: snapshot.radioStation?.nowPlayingArtUrl,
      ),
    ),
  );

  if (playback.isRadioMode) {
    final url = playback.radioArtUrl?.trim() ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || url.isEmpty) {
      return null;
    }
    // Radio art is an external image: no accent from it while the policy
    // refuses it.
    final serverHost = ref.watch(serverHostProvider);
    final allowed = ref.watch(
      integrationPolicyProvider.select(
        (policy) => integrationAllowsArtworkUri(
          policy,
          uri,
          serverHost: serverHost,
          feature: IntegrationFeature.radioNowPlaying,
        ),
      ),
    );
    return allowed ? 'url:$url' : null;
  }

  final currentSongId = playback.currentSongId?.trim() ?? '';
  if (currentSongId.isEmpty) {
    return null;
  }

  final songValue = ref.watch(songByIdProvider(currentSongId));
  if (songValue.isLoading && !songValue.hasValue) {
    return _pendingDynamicAccentSource;
  }
  final coverArtId = songValue.asData?.value?.coverArt?.trim() ?? '';
  return coverArtId.isEmpty ? null : 'id:$coverArtId';
});

@visibleForTesting
final dynamicAccentColorCacheProvider = Provider<DynamicAccentColorCache>((_) {
  return DynamicAccentColorCache();
});

final _dynamicAccentCachedSeedProvider = Provider<int?>((ref) {
  final source = ref.watch(_dynamicAccentSourceProvider);
  if (source == null || source == _pendingDynamicAccentSource) {
    return null;
  }
  return ref.watch(dynamicAccentColorCacheProvider).peek(source);
});

/// Seed color extracted from currently playing cover art/radio art.
///
/// Returns `null` when dynamic accent is disabled or art is unavailable.
final dynamicAccentSeedColorProvider = FutureProvider<int?>((ref) async {
  final source = ref.watch(_dynamicAccentSourceProvider);
  if (source == null) {
    return null;
  }
  if (source == _pendingDynamicAccentSource) {
    // Stay loading so `.value` keeps the previous album's seed.
    return await Completer<int?>().future;
  }

  final cache = ref.watch(dynamicAccentColorCacheProvider);
  final api = ref.watch(subsonicApiProvider);
  return await cache.resolve(
    source: source,
    api: api,
    cacheManager: ref.watch(coverArtCacheManagerProvider),
  );
});

/// The song that plays after the current one, using the order and repeat mode
/// the player itself follows (the logical queue, wrapping only on repeat all).
/// Null for radio, repeat one, the end of the queue, or a queue the snapshot
/// has not caught up with, and for the last item of a shuffled repeat-all
/// queue (the handler reshuffles there, so `ids.first` would be a wrong guess).
String? _nextSongId(PlaybackSnapshot snapshot) {
  final ids = snapshot.queueSongIds;
  final index = snapshot.currentIndex;
  if (snapshot.isRadioMode ||
      index == null ||
      index < 0 ||
      index >= ids.length ||
      ids[index] != snapshot.currentSongId ||
      snapshot.repeatMode == AudioServiceRepeatMode.one) {
    return null;
  }
  if (index + 1 < ids.length) return ids[index + 1];
  if (snapshot.repeatMode != AudioServiceRepeatMode.all ||
      (snapshot.shuffleMode == AudioServiceShuffleMode.all && ids.length > 1)) {
    return null;
  }
  return ids.first;
}

/// Cover source of the next queue item, under the same enabled guard as
/// [_dynamicAccentSourceProvider] and the same metered/offline rule as the
/// audio handler's next-song prefetch. Null when there is nothing worth warming,
/// including when the next cover is the current one (same album).
final _dynamicAccentNextSourceProvider = Provider<String?>((ref) {
  if (!ref.watch(dynamicAccentEnabledProvider)) {
    return null;
  }
  final allowed = nextSongPrefetchAllowed(
    setting: ref.watch(
      appSettingsProvider.select(
        (settings) =>
            settings.asData?.value.prefetchNextOnMobileData ??
            const AppSettingsModel.defaults().prefetchNextOnMobileData,
      ),
    ),
    networkType: ref.watch(networkTypeProvider),
    nativeMetered: ref.watch(nativeNetworkMeteredProvider).asData?.value,
  );
  if (!allowed) {
    return null;
  }
  final nextId = ref.watch(
    playerStateProvider.select(
      (snapshot) => _nextSongId(snapshot)?.trim() ?? '',
    ),
  );
  if (nextId.isEmpty) {
    return null;
  }
  final coverArtId =
      ref.watch(songByIdProvider(nextId)).asData?.value?.coverArt?.trim() ?? '';
  if (coverArtId.isEmpty) {
    return null;
  }
  final source = 'id:$coverArtId';
  return source == ref.watch(_dynamicAccentSourceProvider) ? null : source;
});

/// Resolves the next queue item's album colour into
/// [DynamicAccentColorCache] while the current track plays, so a normal track
/// change finds it cached and the theme fade starts at once. Watched by the
/// app root.
///
/// Bounded by design: only the single next item is ever requested, it starts
/// only after the current track's own colour has resolved (so it never
/// competes with it), and the cache shares any in-flight extraction, so
/// rapid skipping cannot stack up work. Failures are ignored: the normal
/// path still resolves on demand.
final dynamicAccentNextPrefetchProvider = Provider<void>((ref) {
  final source = ref.watch(_dynamicAccentNextSourceProvider);
  if (source == null || ref.watch(dynamicAccentSeedColorProvider).isLoading) {
    return;
  }
  final cache = ref.watch(dynamicAccentColorCacheProvider);
  if (cache.peek(source) != null) {
    return;
  }
  unawaited(
    cache
        .resolve(
          source: source,
          api: ref.watch(subsonicApiProvider),
          cacheManager: ref.watch(coverArtCacheManagerProvider),
        )
        .then<void>((_) {}, onError: (Object _) {}),
  );
});

/// Effective app theme seed: dynamic art-based seed with user-selected fallback.
final effectiveColorSchemeSeedProvider = Provider<int?>((ref) {
  final selectedSeed = ref.watch(colorSchemeSeedProvider);
  // `.value` keeps the previous seed while the next one loads (Riverpod
  // copies the last data into AsyncLoading), so a track change does not flash
  // the selected scheme in between. On error that retained data is stale, so
  // fall back instead of pinning the old album colour forever.
  final seed = ref.watch(dynamicAccentSeedColorProvider);
  final dynamicSeed =
      (seed.hasError ? null : seed.value) ??
      ref.watch(_dynamicAccentCachedSeedProvider);
  return dynamicSeed ?? selectedSeed;
});

@visibleForTesting
class DynamicAccentColorCache {
  final Map<String, int> _seedBySource = <String, int>{};

  /// Extractions under way, so concurrent callers for one source (the current
  /// track, a next-track prefetch and a skip onto it) share a single decode
  /// and quantisation. An entry lives only until its extraction ends, so
  /// failures and `null` results are never remembered.
  final Map<String, Future<int?>> _inFlight = <String, Future<int?>>{};

  int? peek(String source) => _seedBySource[source];

  Future<int?> resolve({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) async {
    final cached = _seedBySource[source];
    if (cached != null) {
      return cached;
    }
    final pending = _inFlight[source];
    if (pending != null) {
      return await pending;
    }

    final image = _toImageProvider(
      source: source,
      api: api,
      cacheManager: cacheManager,
    );
    if (image == null) {
      return null;
    }

    final future = _extractAndStore(source, image);
    _inFlight[source] = future;
    try {
      return await future;
    } finally {
      // The removed future is the one just awaited.
      unawaited(_inFlight.remove(source));
    }
  }

  Future<int?> _extractAndStore(
    String source,
    ImageProvider<Object> image,
  ) async {
    try {
      final seed = await extractSeed(image);
      if (seed != null) {
        _seedBySource[source] = seed;
      }
      return seed;
    } on Object {
      return null;
    }
  }

  /// Decodes [image] and returns the seed colour for it, or `null` when the
  /// image has no usable colour. Overridden in tests.
  @protected
  @visibleForTesting
  Future<int?> extractSeed(ImageProvider<Object> image) async {
    final scheme = await artworkColorScheme(
      provider: image,
      brightness: Brightness.light,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
    return scheme?.primary.toARGB32();
  }

  ImageProvider<Object>? _toImageProvider({
    required String source,
    required SubsonicApiClient? api,
    required BaseCacheManager cacheManager,
  }) {
    if (source.startsWith('url:')) {
      final url = source.substring(4).trim();
      if (url.isEmpty) {
        return null;
      }
      // A `url:` source exists only for radio now-playing art.
      return boundedDecode(
        CachedNetworkImageProvider(
          url,
          cacheManager: cacheManager,
          cacheKey: coverArtFeatureCacheKey(
            IntegrationFeature.radioNowPlaying.key,
            url,
          ),
          headers: coverArtFeatureHeaders(
            IntegrationFeature.radioNowPlaying.key,
          ),
        ),
        width: kPaletteDecodeEdge,
        height: kPaletteDecodeEdge,
      );
    }

    if (source.startsWith('id:')) {
      final id = source.substring(3).trim();
      if (id.isEmpty || api == null) {
        return null;
      }
      return boundedDecode(
        CachedNetworkImageProvider(
          api.getCoverArtUrl(id: id, size: 128).toString(),
          cacheManager: cacheManager,
          cacheKey: coverArtImageCacheKey(id, 128),
        ),
        width: kPaletteDecodeEdge,
        height: kPaletteDecodeEdge,
      );
    }

    return null;
  }
}
