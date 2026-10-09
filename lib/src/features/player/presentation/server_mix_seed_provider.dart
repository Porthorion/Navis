import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/api/subsonic_error.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/song_id_utils.dart';

/// Whether Server Mix can start from `seedSongId`.
///
/// A server-addressable id always can. A remote (`ext-`) id can only when
/// `getSong` maps it to a library copy, the same lookup the recommendation
/// service makes before it asks the server for similar songs. Not known yet,
/// no server and a failed lookup all read as unavailable.
final serverMixSeedAvailableProvider = FutureProvider.autoDispose
    .family<bool, String>((ref, seedSongId) async {
      if (isServerAddressableSongId(seedSongId)) {
        return true;
      }
      final api = ref.watch(subsonicApiProvider);
      if (api == null) {
        return false;
      }
      try {
        final song = await api.getSong(seedSongId);
        final id = song.id.trim();
        return id != seedSongId && isServerAddressableSongId(id);
      } on SubsonicException {
        return false;
      }
    });

/// The synchronous form widgets gate the control on.
bool serverMixSeedAvailable(WidgetRef ref, String seedSongId) =>
    ref.watch(serverMixSeedAvailableProvider(seedSongId)).asData?.value ??
    isServerAddressableSongId(seedSongId);
