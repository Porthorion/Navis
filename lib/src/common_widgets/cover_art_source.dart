import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_api_client.dart';
import 'package:navis/src/common_widgets/cover_art_cache_manager.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Shared cover source selection: durable artwork first, revisioned cache next.
///
/// A refresh revision requests fresh bytes when connected. Offline it still
/// uses the permanent cover, matching CoverArtImage's offline behaviour.
ImageProvider<Object>? coverArtImageProviderFor({
  required String coverArtId,
  required int? size,
  required SubsonicApiClient? api,
  required CacheManager cacheManager,
  File? permanentFile,
  int revision = 0,
}) {
  final id = coverArtId.trim();
  if (id.isEmpty) return null;
  if (permanentFile != null && (revision == 0 || api == null)) {
    return FileImage(permanentFile);
  }
  if (api == null) return null;
  return CachedNetworkImageProvider(
    api.getCoverArtUrl(id: id, size: size).toString(),
    cacheManager: cacheManager,
    cacheKey: coverArtImageCacheKey(id, size, revision: revision),
  );
}

/// Resolves the existing durable store before selecting a cover image source.
final coverArtImageSourceProvider = FutureProvider.autoDispose
    .family<ImageProvider<Object>?, (String, int, int)>((ref, key) async {
      final (id, size, revision) = key;
      final api = ref.watch(subsonicApiProvider);
      final cacheManager = ref.watch(coverArtCacheManagerProvider);
      final store = ref.watch(permanentArtworkStoreProvider);
      final permanent = await store.fileFor(id);
      return coverArtImageProviderFor(
        coverArtId: id,
        size: size,
        revision: revision,
        api: api,
        cacheManager: cacheManager,
        permanentFile: permanent,
      );
    });
