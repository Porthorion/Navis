import 'package:cached_network_image/cached_network_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';

final dynamicAccentEnabledProvider = Provider<bool>((ref) {
  return ref.watch(dynamicAlbumColorEnabledProvider);
});

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
    return url.isEmpty ? null : 'url:$url';
  }

  final currentSongId = playback.currentSongId?.trim() ?? '';
  if (currentSongId.isEmpty) {
    return null;
  }

  final song = ref.watch(songByIdProvider(currentSongId)).asData?.value;
  final coverArtId = song?.coverArt?.trim() ?? '';
  return coverArtId.isEmpty ? null : 'id:$coverArtId';
});

final _dynamicAccentColorCacheProvider = Provider<_DynamicAccentColorCache>((
  _,
) {
  return _DynamicAccentColorCache();
});

final _dynamicAccentCachedSeedProvider = Provider<int?>((ref) {
  final source = ref.watch(_dynamicAccentSourceProvider);
  if (source == null) {
    return null;
  }
  return ref.watch(_dynamicAccentColorCacheProvider).peek(source);
});

/// Seed color extracted from currently playing cover art/radio art.
///
/// Returns `null` when dynamic accent is disabled or art is unavailable.
final dynamicAccentSeedColorProvider = FutureProvider<int?>((ref) async {
  final source = ref.watch(_dynamicAccentSourceProvider);
  if (source == null) {
    return null;
  }

  final cache = ref.watch(_dynamicAccentColorCacheProvider);
  final api = ref.watch(subsonicApiProvider);
  return await cache.resolve(
    source: source,
    api: api,
    cacheManager: ref.watch(coverArtCacheManagerProvider),
  );
});

/// Effective app theme seed: dynamic art-based seed with user-selected fallback.
final effectiveColorSchemeSeedProvider = Provider<int?>((ref) {
  final selectedSeed = ref.watch(colorSchemeSeedProvider);
  final dynamicSeed =
      ref.watch(dynamicAccentSeedColorProvider).asData?.value ??
      ref.watch(_dynamicAccentCachedSeedProvider);
  return dynamicSeed ?? selectedSeed;
});

class _DynamicAccentColorCache {
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
      final scheme = await ColorScheme.fromImageProvider(
        provider: image,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      );
      final seed = scheme.primary.toARGB32();
      _seedBySource[source] = seed;
      return seed;
    } on Exception {
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
      return CachedNetworkImageProvider(url, cacheManager: cacheManager);
    }

    if (source.startsWith('id:')) {
      final id = source.substring(3).trim();
      if (id.isEmpty || api == null) {
        return null;
      }
      return CachedNetworkImageProvider(
        api.getCoverArtUrl(id: id, size: 128).toString(),
        cacheManager: cacheManager,
        cacheKey: coverArtImageCacheKey(id, 128),
      );
    }

    return null;
  }
}
