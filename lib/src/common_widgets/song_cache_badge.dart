import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/common_widgets/cache_badge.dart';
import 'package:navis/src/database/tables/schema_enums.dart';
import 'package:navis/src/providers/app_providers.dart';

/// Builds a [CacheBadge] for a given song ID, or null if the song is not
/// cached. Watches [cachedSongTypesProvider] reactively.
class SongCacheBadge extends ConsumerWidget {
  const new({required this.songId, super.key});

  final String songId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final typesAsync = ref.watch(cachedSongTypesProvider);
    final types = typesAsync.asData?.value;
    if (types == null) return const SizedBox.shrink();

    final cacheType = types[songId];
    if (cacheType == null) return const SizedBox.shrink();

    return CacheBadge(
      type: cacheType == CacheType.permanent
          ? CacheBadgeType.downloaded
          : CacheBadgeType.cached,
    );
  }
}
