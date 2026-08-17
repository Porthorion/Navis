import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/features/cache/data/library_cache_reset_service.dart';
import 'package:navis/src/providers/app_providers.dart';

final libraryCacheResetServiceProvider = Provider<LibraryCacheResetService>((
  ref,
) {
  return LibraryCacheResetService(
    database: ref.watch(navisDatabaseProvider),
    clearCoverArt: () => ref.read(coverArtCacheManagerProvider).emptyCache(),
  );
});
