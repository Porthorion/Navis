import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:navis/src/api/models/models.dart';
import 'package:navis/src/database/navis_database.dart';
import 'package:navis/src/features/player/data/navis_audio_handler.dart';
import 'package:navis/src/features/player/domain/playback_snapshot.dart';
import 'package:navis/src/features/player/presentation/queue_provider.dart';
import 'package:navis/src/providers/app_providers.dart';

import '../../../../helpers/test_database.dart';

class _Handler extends Mock implements NavisPlaybackHandler {}

void main() {
  test(
    'storing a remote copy of a library track relinks it and tells the player',
    () async {
      final database = createTestDatabase();
      addTearDown(database.close);
      final handler = _Handler();
      when(() => handler.applySongIdentityAliases(any()))
          .thenAnswer((_) async {});
      when(() => handler.snapshotStream)
          .thenAnswer((_) => const Stream<PlaybackSnapshot>.empty());
      when(() => handler.snapshot).thenReturn(const PlaybackSnapshot.idle());
      await database
          .into(database.songsTable)
          .insert(
            SongsTableData(
              id: 'lib',
              title: 'Set Fire to the Rain',
              artistName: 'Adele',
              albumName: '21',
              duration: 238,
              track: 5,
              discNumber: 1,
              isProvisional: false,
              isExternal: false,
            ),
          );
      final container = ProviderContainer(
        overrides: [
          ...withTestDatabase(database),
          audioHandlerProvider.overrideWithValue(handler),
        ],
      );
      addTearDown(container.dispose);

      await container.read(queueProvider.notifier).storeProvisionalSongs(<Song>[
        const Song(
          id: 'ext-deezer-song-8086130',
          title: 'Set Fire to the Rain',
          artist: 'Adele',
          album: '21',
          duration: 242,
          track: 5,
          discNumber: 1,
          isExternal: true,
        ),
      ]);

      expect(
        await database.libraryDao.getSongById('ext-deezer-song-8086130'),
        isNull,
      );
      expect(
        await database.songIdentityDao.resolveCanonicalId(
          'ext-deezer-song-8086130',
        ),
        'lib',
      );
      verify(
        () => handler.applySongIdentityAliases(<String, String>{
          'ext-deezer-song-8086130': 'lib',
        }),
      ).called(1);
    },
    skip: !sqliteAvailable,
  );

  group('queue entry points hand the library id to the player', () {
    const extId = 'ext-deezer-song-8086130';
    final library = SongsTableData(
      id: 'lib',
      title: 'Set Fire to the Rain',
      artistName: 'Adele',
      albumName: '21',
      duration: 238,
      track: 5,
      discNumber: 1,
      isProvisional: false,
      isExternal: false,
    );
    final remote = SongsTableData(
      id: extId,
      title: 'Set Fire to the Rain',
      artistName: 'Adele',
      albumName: '21',
      duration: 242,
      track: 5,
      discNumber: 1,
      isProvisional: true,
      isExternal: true,
    );

    for (final entry in <String>[
      'replace',
      'replaceWithTableData',
      'add',
      'addTableData',
      'playNext',
    ]) {
      test(entry, () async {
        final database = createTestDatabase();
        addTearDown(database.close);
        final handler = _Handler();
        when(() => handler.applySongIdentityAliases(any()))
            .thenAnswer((_) async {});
        when(() => handler.snapshotStream)
            .thenAnswer((_) => const Stream<PlaybackSnapshot>.empty());
        when(() => handler.snapshot).thenReturn(const PlaybackSnapshot.idle());
        when(
          () => handler.replaceQueue(
            any(),
            startIndex: any(named: 'startIndex'),
            autoPlay: any(named: 'autoPlay'),
            expandMatchFlows: any(named: 'expandMatchFlows'),
            originalOrder: any(named: 'originalOrder'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => handler.replaceQueueWithData(
            any(),
            startIndex: any(named: 'startIndex'),
            autoPlay: any(named: 'autoPlay'),
            expandMatchFlows: any(named: 'expandMatchFlows'),
            originalOrder: any(named: 'originalOrder'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => handler.addToQueue(
            any(),
            expandMatchFlows: any(named: 'expandMatchFlows'),
          ),
        ).thenAnswer((_) async {});
        when(
          () => handler.playNext(
            any(),
            expandMatchFlows: any(named: 'expandMatchFlows'),
          ),
        ).thenAnswer((_) async {});
        await database.into(database.songsTable).insert(library);
        await database.into(database.songsTable).insert(remote);
        final container = ProviderContainer(
          overrides: [
            ...withTestDatabase(database),
            audioHandlerProvider.overrideWithValue(handler),
            lyricsPrewarmProvider.overrideWithValue((_) async {}),
          ],
        );
        addTearDown(container.dispose);
        final queue = container.read(queueProvider.notifier);

        switch (entry) {
          case 'replace':
            await queue.replace(<String>[extId]);
            expect(
              verify(
                () => handler.replaceQueue(
                  captureAny(),
                  startIndex: any(named: 'startIndex'),
                  autoPlay: any(named: 'autoPlay'),
                  expandMatchFlows: any(named: 'expandMatchFlows'),
                  originalOrder: any(named: 'originalOrder'),
                ),
              ).captured.single,
              <String>['lib'],
            );
          case 'replaceWithTableData':
            await queue.replaceWithTableData(<SongsTableData>[remote]);
            final rows =
                verify(
                      () => handler.replaceQueueWithData(
                        captureAny(),
                        startIndex: any(named: 'startIndex'),
                        autoPlay: any(named: 'autoPlay'),
                        expandMatchFlows: any(named: 'expandMatchFlows'),
                        originalOrder: any(named: 'originalOrder'),
                      ),
                    ).captured.single
                    as List<SongsTableData>;
            expect(rows.map((row) => row.id), <String>['lib']);
          case 'add':
            await queue.add(extId);
            expect(
              verify(
                () => handler.addToQueue(
                  captureAny(),
                  expandMatchFlows: any(named: 'expandMatchFlows'),
                ),
              ).captured.single,
              <String>['lib'],
            );
          case 'addTableData':
            await queue.addTableData(<SongsTableData>[remote]);
            expect(
              verify(
                () => handler.addToQueue(
                  captureAny(),
                  expandMatchFlows: any(named: 'expandMatchFlows'),
                ),
              ).captured.single,
              <String>['lib'],
            );
          case _:
            await queue.playNext(extId);
            expect(
              verify(
                () => handler.playNext(
                  captureAny(),
                  expandMatchFlows: any(named: 'expandMatchFlows'),
                ),
              ).captured.single,
              <String>['lib'],
            );
        }
        expect(await database.libraryDao.getSongById(extId), isNull);
      }, skip: !sqliteAvailable);
    }
  });
}
