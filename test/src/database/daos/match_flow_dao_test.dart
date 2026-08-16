import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navis/src/database/daos/match_flow_dao.dart';
import 'package:navis/src/database/navis_database.dart';

void main() {
  group('MatchFlowDao', () {
    late NavisDatabase database;

    setUp(() async {
      database = NavisDatabase(NativeDatabase.memory());
      await _seedSongs(database, const <String>[
        'master-a',
        'child-b',
        'child-c',
        'master-x',
        'child-y',
        'plain-p',
        'nested-d',
      ]);
    });

    tearDown(() async {
      await database.close();
    });

    test('creates, renames, toggles, and deletes flows', () async {
      final settings = await database.appSettingsDao.getSettings();
      expect(settings?.matchFlowEnabled, isFalse);

      final id = await database.matchFlowDao.createFlow();

      var flows = await database.matchFlowDao.getFlowsWithSongs();
      expect(flows, hasLength(1));
      expect(flows.single.flow.id, id);
      expect(flows.single.flow.name, MatchFlowDao.defaultFlowName);
      expect(flows.single.flow.enabled, isTrue);

      await database.matchFlowDao.renameFlow(id, 'Road trip');
      await database.matchFlowDao.setFlowEnabled(id, enabled: false);

      flows = await database.matchFlowDao.getFlowsWithSongs();
      expect(flows.single.flow.name, 'Road trip');
      expect(flows.single.flow.enabled, isFalse);

      await database.matchFlowDao.deleteFlow(id);
      expect(await database.matchFlowDao.getFlowsWithSongs(), isEmpty);
    });

    test('adds, removes, and reorders songs', () async {
      final flowId = await database.matchFlowDao.createFlow();

      await database.matchFlowDao.addSong(flowId, 'master-a');
      await database.matchFlowDao.addSong(flowId, 'child-b');
      await database.matchFlowDao.addSong(flowId, 'child-c');
      await database.matchFlowDao.reorderSong(
        flowId,
        'child-c',
        newIndex: 1,
      );
      await database.matchFlowDao.removeSong(flowId, 'child-b');

      final flow = (await database.matchFlowDao.getFlowsWithSongs()).single;
      expect(
        flow.songs.map((entry) => entry.link.songId),
        <String>['master-a', 'child-c'],
      );
      expect(
        flow.songs.map((entry) => entry.link.sortOrder),
        <int>[0, 1],
      );
    });

    test('rejects duplicate songs inside the same flow', () async {
      final flowId = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(flowId, 'master-a');

      expect(
        () => database.matchFlowDao.addSong(flowId, 'master-a'),
        throwsA(
          isA<MatchFlowException>().having(
            (error) => error.failure,
            'failure',
            MatchFlowFailure.songAlreadyInFlow,
          ),
        ),
      );
    });

    test('rejects master conflicts across disabled flows', () async {
      final first = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(first, 'master-a');
      await database.matchFlowDao.setFlowEnabled(first, enabled: false);

      final second = await database.matchFlowDao.createFlow();
      expect(
        () => database.matchFlowDao.addSong(second, 'master-a'),
        throwsA(
          isA<MatchFlowException>().having(
            (error) => error.failure,
            'failure',
            MatchFlowFailure.masterInAnotherFlow,
          ),
        ),
      );
    });

    test(
      'rejects reordering a conflicting song into master position',
      () async {
        final second = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(second, 'master-x');
        await database.matchFlowDao.addSong(second, 'child-b');

        final first = await database.matchFlowDao.createFlow();
        await database.matchFlowDao.addSong(first, 'master-a');
        await database.matchFlowDao.addSong(first, 'master-x');

        expect(
          () => database.matchFlowDao.reorderSong(
            first,
            'master-x',
            newIndex: 0,
          ),
          throwsA(
            isA<MatchFlowException>().having(
              (error) => error.failure,
              'failure',
              MatchFlowFailure.masterInAnotherFlow,
            ),
          ),
        );
      },
    );

    test('expands enabled masters and remaps start index', () async {
      final first = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(first, 'master-a');
      await database.matchFlowDao.addSong(first, 'child-b');
      await database.matchFlowDao.addSong(first, 'child-c');

      final second = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(second, 'master-x');
      await database.matchFlowDao.addSong(second, 'child-y');

      final result = await database.matchFlowDao.expandQueueSongIds(
        const <String>['plain-p', 'master-a', 'master-x'],
        startIndex: 2,
        enabled: true,
      );

      expect(
        result.songIds,
        <String>[
          'plain-p',
          'master-a',
          'child-b',
          'child-c',
          'master-x',
          'child-y',
        ],
      );
      expect(result.startIndex, 4);
    });

    test('does not expand when global setting or flow is disabled', () async {
      final flowId = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(flowId, 'master-a');
      await database.matchFlowDao.addSong(flowId, 'child-b');

      var result = await database.matchFlowDao.expandQueueSongIds(
        const <String>['master-a'],
        startIndex: 0,
        enabled: false,
      );
      expect(result.songIds, <String>['master-a']);

      await database.matchFlowDao.setFlowEnabled(flowId, enabled: false);
      result = await database.matchFlowDao.expandQueueSongIds(
        const <String>['master-a'],
        startIndex: 0,
        enabled: true,
      );
      expect(result.songIds, <String>['master-a']);
    });

    test('does not recursively expand inserted flow songs', () async {
      final first = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(first, 'master-a');
      await database.matchFlowDao.addSong(first, 'child-b');
      await database.matchFlowDao.addSong(first, 'child-c');

      final second = await database.matchFlowDao.createFlow();
      await database.matchFlowDao.addSong(second, 'child-b');
      await database.matchFlowDao.addSong(second, 'nested-d');

      final result = await database.matchFlowDao.expandQueueSongIds(
        const <String>['master-a'],
        startIndex: 0,
        enabled: true,
      );

      expect(result.songIds, <String>['master-a', 'child-b', 'child-c']);
    });
  });
}

Future<void> _seedSongs(NavisDatabase database, List<String> ids) {
  return database.libraryDao.upsertSongs(
    ids
        .map(
          (id) => SongsTableCompanion.insert(
            id: id,
            title: id,
          ),
        )
        .toList(growable: false),
  );
}
