import 'dart:async';

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
      // Candidates come from the search index.
      await database.libraryDao.scheduleSongSearchIndexRefresh();
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

  test(
    'a remote single relinks to the album track and search lists one row',
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
              duration: 243,
              track: 2,
              discNumber: 1,
              isProvisional: false,
              isExternal: false,
            ),
          );
      await database.libraryDao.scheduleSongSearchIndexRefresh();
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
          album: 'Set Fire to the Rain - Single',
          duration: 242,
          track: 1,
          discNumber: 1,
          isExternal: true,
        ),
      ]);

      expect(
        (await database.libraryDao.searchCachedSongs('set fire'))
            .map((song) => song.id),
        <String>['lib'],
      );
      verify(
        () => handler.applySongIdentityAliases(<String, String>{
          'ext-deezer-song-8086130': 'lib',
        }),
      ).called(1);
    },
    skip: !sqliteAvailable,
  );

  group('queue entry points hand over first, then relink once', () {
    const extId = 'ext-deezer-song-8086130';
    SongsTableData row(String id, {required bool external}) => SongsTableData(
      id: id,
      title: 'Set Fire to the Rain',
      artistName: 'Adele',
      albumName: '21',
      duration: 238,
      track: 5,
      discNumber: 1,
      isProvisional: external,
      isExternal: external,
    );

    late _BatchHandler handler;
    late List<List<String>> relinkCalls;
    late Completer<Map<String, String>> gate;
    late ProviderContainer container;
    late List<String> events;

    setUp(() async {
      final database = createTestDatabase();
      addTearDown(database.close);
      handler = _BatchHandler();
      relinkCalls = [];
      events = [];
      gate = Completer<Map<String, String>>();
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
      ).thenAnswer((invocation) async {
        events.add(
          'replace ${(invocation.positionalArguments.first as List).join(',')}',
        );
      });
      when(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: any(named: 'startIndex'),
          autoPlay: any(named: 'autoPlay'),
          expandMatchFlows: any(named: 'expandMatchFlows'),
          originalOrder: any(named: 'originalOrder'),
        ),
      ).thenAnswer((invocation) async {
        events.add(
          'replaceData ${(invocation.positionalArguments.first as List<SongsTableData>).map((r) => r.id).join(',')}',
        );
      });
      when(
        () => handler.addToQueue(
          any(),
          expandMatchFlows: any(named: 'expandMatchFlows'),
        ),
      ).thenAnswer((invocation) async {
        events.add(
          'add ${(invocation.positionalArguments.first as List).join(',')}',
        );
      });
      when(
        () => handler.playNext(
          any(),
          expandMatchFlows: any(named: 'expandMatchFlows'),
        ),
      ).thenAnswer((invocation) async {
        events.add(
          'next ${(invocation.positionalArguments.first as List).join(',')}',
        );
      });
      when(
        () => handler.mergeIntoUpcoming(
          any(),
          notBefore: any(named: 'notBefore'),
          random: any(named: 'random'),
        ),
      ).thenAnswer(
        (_) async =>
            const QueueBatchEditResult(skippedSongIds: <String>[extId]),
      );
      when(() => handler.insertQueueRuns(any())).thenAnswer(
        (_) async =>
            const QueueBatchEditResult(skippedSongIds: <String>[extId]),
      );
      container = ProviderContainer(
        overrides: [
          ...withTestDatabase(database),
          audioHandlerProvider.overrideWithValue(handler),
          lyricsPrewarmProvider.overrideWithValue((_) async {}),
          relinkExternalCopiesProvider.overrideWithValue((ids) {
            relinkCalls.add(ids.toList());
            events.add('relink');
            return gate.future;
          }),
        ],
      );
      addTearDown(container.dispose);
    });

    test('replace hands the ids over unchanged, then relinks them', () async {
      await container.read(queueProvider.notifier).replace(<String>[extId]);

      expect(events, <String>['replace $extId', 'relink']);
      expect(relinkCalls, [
        [extId],
      ]);
    }, skip: !sqliteAvailable);

    test('a held relink never reorders a newer tap', () async {
      final queue = container.read(queueProvider.notifier);
      await queue.replace(<String>[extId]);
      await queue.replace(<String>['song-b']);

      // The relink is still open (gate): the newer tap went straight through.
      expect(events, <String>['replace $extId', 'relink', 'replace song-b']);
      gate.complete(const <String, String>{});
    }, skip: !sqliteAvailable);

    test('a library song and its remote copy are queued once each', () async {
      await container.read(queueProvider.notifier).replaceWithTableData(
        <SongsTableData>[
          row('lib', external: false),
          row(extId, external: true),
        ],
      );

      expect(events, <String>['replaceData lib,$extId', 'relink']);
      expect(relinkCalls, [
        [extId],
      ]);
      verify(
        () => handler.replaceQueueWithData(
          any(),
          startIndex: any(named: 'startIndex'),
          autoPlay: any(named: 'autoPlay'),
          expandMatchFlows: any(named: 'expandMatchFlows'),
          originalOrder: any(named: 'originalOrder'),
        ),
      ).called(1);
    }, skip: !sqliteAvailable);

    test('add, addTableData and playNext keep their ids', () async {
      final queue = container.read(queueProvider.notifier);
      await queue.add(extId);
      await queue.addTableData(<SongsTableData>[row(extId, external: true)]);
      await queue.playNext(extId);

      expect(events, <String>[
        'add $extId',
        'relink',
        'add $extId',
        'relink',
        'next $extId',
        'relink',
      ]);
    }, skip: !sqliteAvailable);

    test('mergeIntoUpcoming and insertRuns return the ids the editor '
        'skipped and relink all runs once', () async {
      final queue = container.read(queueProvider.notifier);
      final remote = row(extId, external: true);

      expect(
        await queue.mergeIntoUpcoming(<SongsTableData>[remote], notBefore: 0),
        <String>[extId],
      );
      relinkCalls.clear();
      expect(
        await queue.insertRuns(<QueueInsertRun>[
          QueueInsertRun(0, <SongsTableData>[remote]),
          QueueInsertRun(3, <SongsTableData>[
            row('ext-deezer-song-2', external: true),
          ]),
        ]),
        <String>[extId],
      );
      expect(relinkCalls, [
        [extId, 'ext-deezer-song-2'],
      ]);
    }, skip: !sqliteAvailable);

    test('a library-only batch does not relink', () async {
      await container.read(queueProvider.notifier).replace(<String>['lib']);

      expect(relinkCalls, isEmpty);
    }, skip: !sqliteAvailable);
  });

  test('relinks run one at a time, in order', () async {
    final first = Completer<Map<String, String>>();
    final log = <String>[];
    final relink = serializeRelinks((ids) {
      log.add('start ${ids.join()}');
      if (log.length == 1) return first.future;
      return Future.value(const <String, String>{});
    });

    final a = relink(['a']);
    final b = relink(['b']);
    await pumpEventQueue();
    expect(log, ['start a']);

    first.complete(const <String, String>{'a': 'lib'});
    expect(await a, {'a': 'lib'});
    await b;
    expect(log, ['start a', 'start b']);
  });
}

class _BatchHandler extends _Handler implements QueueBatchEditor {}
