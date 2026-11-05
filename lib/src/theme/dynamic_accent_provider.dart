import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/features/integrations/domain/integration_artwork.dart';
import 'package:navis/src/features/integrations/domain/integration_feature.dart';
import 'package:navis/src/providers/app_providers.dart';

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

/// Seed colour of the server cover `coverArtId`, from the same cache the
/// player's album colour uses, for a flat tint behind a card. It does not
/// follow the Dynamic Album Color setting (that one replaces the app accent).
/// `null` while it resolves, or when the cover has no usable colour.
final artworkSeedColorProvider = FutureProvider.autoDispose
    .family<int?, String>(
      (ref, coverArtId) => ref
          .watch(dynamicAccentColorCacheProvider)
          .resolve(
            source: 'id:$coverArtId',
            api: ref.watch(subsonicApiProvider),
            cacheManager: ref.watch(coverArtCacheManagerProvider),
          ),
    );

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

class DynamicAccentColorCache {
  final Map<String, int> _seedBySource = <String, int>{};

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

    final image = _toImageProvider(
      source: source,
      api: api,
      cacheManager: cacheManager,
    );
    if (image == null) {
      return null;
    }

    try {
      final scheme = await artworkColorScheme(
        provider: image,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      if (scheme == null) return null;
      final seed = scheme.primary.toARGB32();
      _seedBySource[source] = seed;
      return seed;
    } on Object {
      return null;
    }
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
