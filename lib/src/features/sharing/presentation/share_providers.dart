import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cover_art_image.dart';
import 'package:navis/src/features/sharing/data/share_service.dart';
import 'package:navis/src/providers/app_providers.dart';

final shareServiceProvider = Provider<ShareService>((ref) {
  // coverArtCacheManagerProvider is a StreamProvider<CacheManager>.
  // Use .asData?.value to get the current cache manager, falling back to
  // the module-level defaultCoverArtCacheManager if the stream hasn't
  // emitted yet.
  final cacheManager =
      ref.watch(coverArtCacheManagerProvider).asData?.value ??
      defaultCoverArtCacheManager;
  return ShareService(
    apiClient: ref.watch(subsonicApiProvider),
    cacheManager: cacheManager,
  );
});
