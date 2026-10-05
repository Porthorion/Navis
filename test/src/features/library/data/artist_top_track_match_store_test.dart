import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/api/models/song.dart';
import 'package:navis/src/features/integrations/data/integration_json_cache.dart';
import 'package:navis/src/features/library/data/artist_top_track_match_store.dart';

void main() {
  test(
    'server/account scopes isolate identical artist and chart IDs',
    () async {
      final root = Directory.systemTemp.createTempSync('match-scopes-');
      addTearDown(() => root.deleteSync(recursive: true));
      final cache = IntegrationJsonCache(readRootDirectory: () async => root);
      final first = ArtistTopTrackMatchStore(
        cache: cache,
        accountScope: 'first',
      );
      final second = ArtistTopTrackMatchStore(
        cache: cache,
        accountScope: 'second',
      );
      for (final artist in ['artist-1', 'deezer-chart']) {
        await first.save(artist, {
          'seed': ArtistTopTrackMatchEntry(
            songId: 'old-server-id',
            remoteSong: const Song(id: 'old-server-id', title: 'Old'),
            checkedAt: DateTime.now(),
          ),
        }, generation: first.generation);
        expect(await first.load(artist), contains('seed'));
        expect(await second.load(artist), isEmpty);
      }
      final generation = first.generation;
      first.invalidate();
      await first.save('late', {
        'seed': ArtistTopTrackMatchEntry.unmatched(checkedAt: DateTime.now()),
      }, generation: generation);
      expect(await first.load('late'), isEmpty);
    },
  );
}
