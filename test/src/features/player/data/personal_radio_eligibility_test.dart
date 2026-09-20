import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/features/player/data/recommendation_service.dart';
import 'package:navis/src/providers/app_providers.dart';
import 'package:navis/src/utils/connectivity.dart';

import '../../../../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'offline radio accepts valid local files and rejects catalog-only songs',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final directory = await Directory.systemTemp.createTemp(
        'navis-radio-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final permanent = File('${directory.path}/permanent.mp3');
      final rolling = File('${directory.path}/rolling.mp3');
      await permanent.writeAsBytes(<int>[1]);
      await rolling.writeAsBytes(<int>[2]);

      for (final id in <String>['permanent', 'rolling', 'catalog', 'missing']) {
        await database.customStatement(
          'INSERT INTO songs (id, title, artist_name, is_provisional, is_external) '
          'VALUES (?, ?, ?, 0, 0)',
          <Object?>[id, id, 'Artist'],
        );
      }
      for (final (id, path, type) in <(String, String, String)>[
        ('permanent', permanent.path, 'permanent'),
        ('rolling', rolling.path, 'rolling'),
        ('missing', '${directory.path}/missing.mp3', 'permanent'),
      ]) {
        await database.customStatement(
          'INSERT INTO cached_tracks '
          '(song_id, file_path, file_size, format, last_accessed_at, cache_type, download_status) '
          'VALUES (?, ?, 1, ?, 0, ?, ?)',
          <Object?>[id, path, 'mp3', type, 'complete'],
        );
      }

      final container = ProviderContainer(
        overrides: [
          navisDatabaseProvider.overrideWithValue(database),
          networkTypeProvider.overrideWithValue(NetworkType.offline),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(recommendationServiceProvider);

      final offline = await service.eligibleLibrary(const RadioFilters());
      expect(offline.map((song) => song.id).toSet(), <String>{
        'permanent',
        'rolling',
      });
      final downloaded = await service.eligibleLibrary(
        const RadioFilters(downloadedOnly: true),
      );
      expect(downloaded.map((song) => song.id), <String>['permanent']);
    },
  );
}
