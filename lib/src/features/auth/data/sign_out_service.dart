import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/auth/data/server_config_repository.dart';
import 'package:navis/src/features/auth/presentation/server_config_provider.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/app_logger.dart';
import 'package:navis/src/utils/file_utils.dart';

final signOutServiceProvider = Provider<SignOutService>((ref) {
  final repository = ref.watch(serverConfigRepositoryProvider);
  final database = ref.watch(navisDatabaseProvider);
  return SignOutService(
    serverConfigRepository: repository,
    database: database,
  );
});

class SignOutService {
  const SignOutService({
    required ServerConfigRepository serverConfigRepository,
    required NavisDatabase database,
  }) : _serverConfigRepository = serverConfigRepository,
       _database = database;

  final ServerConfigRepository _serverConfigRepository;
  final NavisDatabase _database;

  Future<void> signOut({required bool wipeLocalData}) async {
    final cachedTracks = wipeLocalData
        ? await _database.cacheDao.getCachedTracks()
        : const <CachedTracksTableData>[];

    await _database.starSyncDao.clearAll();
    await _serverConfigRepository.clear();

    if (!wipeLocalData) {
      return;
    }

    await _database.playQueueDao.clearQueue();
    await _database.downloadQueueDao.clearQueue();
    await _database.historyDao.clearAllHistory();
    await _database.playlistDao.clearAllPlaylists();
    await _database.cacheDao.clearCachedTracks();
    await _database.libraryDao.clearLibraryData();

    for (final track in cachedTracks) {
      try {
        await deleteFileWithSuffixes(track.filePath);
      } on Object catch (error) {
        AppLogger.warning(
          'Unable to delete cached track file during sign out: ${track.filePath}. '
          'Error: $error',
        );
      }
    }
  }
}
